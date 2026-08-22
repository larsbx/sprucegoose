defmodule SpruceGoose.Derivations.Executor do
  @moduledoc """
  Executes one typed derivation permit through an allowlisted handler.

  Jobs carry only a permit ID. Source identity, action, authorization, and
  lifecycle remain in SpruceGoose; repository workflow commands are never job
  input.
  """

  use Oban.Worker,
    queue: :derivations,
    max_attempts: 1,
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
      {:ok, result} -> result
      {:error, reason} -> {:discard, message(reason)}
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
    result =
      try do
        handler.run(permit)
      rescue
        exception -> {:error, Exception.message(exception)}
      catch
        kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
      end

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
      {:error, reason} -> Repo.rollback(reason)
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
