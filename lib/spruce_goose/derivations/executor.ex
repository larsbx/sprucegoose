defmodule SpruceGoose.Derivations.Executor do
  @moduledoc """
  Executes one typed derivation permit through an allowlisted handler.

  Jobs carry only a permit ID. Source identity, action, authorization, and
  lifecycle remain in SpruceGoose; repository workflow commands are never job
  input.
  """

  # A handler failure is a terminal outcome and commits a receipt, so it needs no
  # retry. A *receipt-write* failure is infrastructure: at max_attempts: 1 it
  # discarded the job and left the permit with no terminal outcome and no way
  # back, which is the one thing this worker exists to prevent. Retries are
  # therefore reserved for that case — `perform/1` returns `:discard` for every
  # outcome that was successfully recorded, so a retry only ever follows a
  # failure to record one.
  use Oban.Worker,
    queue: :derivations,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :args]]

  require Ash.Query

  alias SpruceGoose.Actors.Actor
  alias SpruceGoose.Authz
  alias SpruceGoose.Derivations.{OutcomeReceipt, Permit}
  alias SpruceGoose.Kernel.{Canonical, CertifiedEvent, ContentID}
  alias SpruceGoose.Kernel.Postgres.EventLedger
  alias SpruceGoose.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"permit_id" => permit_id}} = job)
      when map_size(job.args) == 1 and is_binary(permit_id) do
    with {:ok, actor} <- executor_actor() do
      Authz.with_actor(actor, fn -> execute(permit_id, actor.name) end)
    else
      {:error, reason} -> {:discard, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, "expected exactly one permit_id"}

  defp execute(permit_id, executor_id) do
    # AUTHORIZATION: executor_actor/0 resolved an active derivation_executor before this transaction.
    case Repo.transaction(fn -> execute_locked(permit_id, executor_id) end) do
      {:ok, result} ->
        result

      # Only a failure to *record* an outcome is worth another attempt. An
      # absent permit or an already-terminal one will not improve.
      {:error, {:retry, reason}} ->
        {:error, message(reason)}

      {:error, reason} ->
        {:discard, message(reason)}
    end
  end

  defp execute_locked(permit_id, executor_id) do
    # AUTHORIZATION: the actor-bound executor serializes only the immutable permit it was asked to run.
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [permit_id])

    with {:ok, permit} <- Authz.read_one(Permit, permit_id: permit_id),
         {:ok, nil} <- existing_receipt(permit_id) do
      run_handler(permit, executor_id)
    else
      {:ok, %OutcomeReceipt{}} -> Repo.rollback("derivation already has a terminal receipt")
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp run_handler(permit, executor_id) do
    case handler_for(permit.action) do
      {:ok, handler} ->
        invoke_handler(handler, permit, executor_id)

      {:error, reason} ->
        record_failure(permit, executor_id, reason)
    end
  end

  defp invoke_handler(handler, permit, executor_id) do
    result = run_in_savepoint(handler, permit)

    case result do
      {:ok, %{evidence_digest: evidence} = outcome} ->
        record_outcome(permit, %{
          executor_id: executor_id,
          outcome: :succeeded,
          evidence_digest: evidence,
          artifact_digest: Map.get(outcome, :artifact_digest)
        })

      {:error, reason} ->
        record_failure(permit, executor_id, message(reason))

      other ->
        record_failure(
          permit,
          executor_id,
          "handler returned malformed outcome: #{inspect(other)}"
        )
    end
  end

  # The handler runs inside the transaction that will record its outcome, so an
  # exception raised by PostgreSQL leaves that transaction aborted and every
  # later statement failing with 25P02 — the failure receipt could not be
  # written for exactly the class of failure where it matters most.
  #
  # A savepoint scopes the damage: rolling back to it restores a usable
  # transaction, so the outcome is recordable whatever the handler did.
  @savepoint "derivation_handler"

  defp run_in_savepoint(handler, permit) do
    savepoint("SAVEPOINT")

    try do
      case handler.run(permit) do
        {:ok, _outcome} = ok ->
          savepoint("RELEASE SAVEPOINT")
          ok

        other ->
          savepoint("ROLLBACK TO SAVEPOINT")
          other
      end
    rescue
      exception ->
        savepoint("ROLLBACK TO SAVEPOINT")
        {:error, Exception.message(exception)}
    catch
      kind, reason ->
        savepoint("ROLLBACK TO SAVEPOINT")
        {:error, "#{kind}: #{inspect(reason)}"}
    end
  end

  defp savepoint(statement) do
    # AUTHORIZATION: executor_actor/0 resolved an active derivation_executor before this
    # transaction. These statements only bound the handler's failure; they read no data.
    Repo.query!("#{statement} #{@savepoint}")
  end

  defp record_failure(permit, executor_id, reason) do
    case record_outcome(permit, %{
           executor_id: executor_id,
           outcome: :failed,
           failure_reason: reason
         }) do
      :ok -> {:discard, reason}
      other -> other
    end
  end

  defp record_outcome(permit, attrs) do
    payload = %{
      "permit_id" => permit.permit_id,
      "executor_id" => attrs.executor_id,
      "outcome" => to_string(attrs.outcome),
      "evidence_digest" => Map.get(attrs, :evidence_digest),
      "artifact_digest" => Map.get(attrs, :artifact_digest),
      "failure_reason" => Map.get(attrs, :failure_reason),
      "roots" => permit.roots
    }

    with {:ok, bytes} <- Canonical.encode(payload),
         {:ok, %ContentID{digest: digest}} <- ContentID.derive(:sha256, bytes),
         receipt_attrs <-
           attrs
           |> Map.put(:task_id, permit.task_id)
           |> Map.put(:permit_id, permit.permit_id)
           |> Map.put(:roots, permit.roots)
           |> Map.put(:receipt_id, "drr-" <> digest),
         {:ok, receipt, _notifications} <-
           Authz.create_with_notifications(OutcomeReceipt, receipt_attrs, action: :record),
         {:ok, event} <- certified_event(receipt),
         {:ok, _identity, _ledger} <- EventLedger.append(EventLedger.new(), event) do
      :ok
    else
      {:error, reason} -> Repo.rollback({:retry, reason})
    end
  end

  defp certified_event(receipt) do
    CertifiedEvent.new(%{
      stream: "derivation:" <> receipt.permit_id,
      event_type: "DerivationOutcomeCertified",
      idempotency_key: receipt.receipt_id,
      payload: %{
        "receipt_id" => receipt.receipt_id,
        "permit_id" => receipt.permit_id,
        "executor_id" => receipt.executor_id,
        "outcome" => to_string(receipt.outcome),
        "evidence_digest" => receipt.evidence_digest,
        "artifact_digest" => receipt.artifact_digest,
        "failure_reason" => receipt.failure_reason
      },
      roots: receipt.roots
    })
  end

  defp existing_receipt(permit_id) do
    OutcomeReceipt
    |> Ash.Query.filter_input(permit_id: permit_id)
    |> Authz.read()
    |> case do
      {:ok, []} -> {:ok, nil}
      {:ok, [receipt]} -> {:ok, receipt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handler_for(action) do
    handlers = Application.get_env(:spruce_goose, :derivation_handlers, %{})

    case Map.get(handlers, action) do
      nil ->
        {:error, "no handler configured for #{action}"}

      handler when is_atom(handler) ->
        if Code.ensure_loaded?(handler) and function_exported?(handler, :run, 1),
          do: {:ok, handler},
          else: {:error, "invalid handler configured for #{action}"}

      _other ->
        {:error, "invalid handler configured for #{action}"}
    end
  end

  defp executor_actor do
    name = Application.get_env(:spruce_goose, :derivation_executor_actor)

    if is_binary(name) and name != "" do
      result =
        Actor
        |> Ash.Query.filter_input(name: name)
        |> Ash.read_one(authorize?: false)

      case result do
        {:ok, %Actor{} = actor} ->
          if Actor.active?(actor),
            do: {:ok, actor},
            else: {:error, "derivation executor is disabled"}

        _ ->
          {:error, "derivation executor actor is not configured"}
      end
    else
      {:error, "derivation executor actor is not configured"}
    end
  end

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason) when is_exception(reason), do: Exception.message(reason)
  defp message(reason), do: inspect(reason)
end
