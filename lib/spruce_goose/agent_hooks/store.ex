defmodule SpruceGoose.AgentHooks.Store do
  @moduledoc false
  import Ecto.Query

  alias SpruceGoose.Actors.{Actor, Scope}
  alias SpruceGoose.AgentHooks.{Config, Delivery, Proposal, Run, TriageResult, Worker}
  alias SpruceGoose.{Authz, Repo}
  alias SpruceGoose.Outbox.Event

  def schedule(%Event{} = event) do
    # AUTHORIZATION: only a persisted capture and a configured, current global proposer may create a run.
    Repo.transaction(fn ->
      registry_lock()

      config =
        case Config.current() do
          {:ok, config} -> config
          {:error, reason} -> Repo.rollback(reason)
        end

      run_key =
        Config.digest(%{
          "event_key" => event.event_key,
          "hook_id" => "inbox-triage",
          "version" => 1
        })

      sql("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", ["agent-hook:" <> run_key])

      case Ash.read_one(Run |> Ash.Query.filter_input(run_key: run_key), authorize?: false) do
        {:ok, %Run{id: id}} -> id
        {:ok, nil} -> create_run(event, config, run_key)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp create_run(event, config, run_key) do
    with %Event{} = stored <- Repo.get(Event, event.id),
         true <-
           Map.take(stored, [:event_key, :aggregate_type, :aggregate_id, :event_type, :payload]) ==
             Map.take(event, [:event_key, :aggregate_type, :aggregate_id, :event_type, :payload]),
         true <- stored.aggregate_type == "inbox" and stored.event_type == "inbox.captured",
         %{"id" => inbox_id, "capture_id" => capture_id, "body" => body, "state" => "pending"} <-
           stored.payload,
         {:ok, ^inbox_id} <- Ecto.UUID.cast(inbox_id),
         true <- capture_id == stored.aggregate_id and stored.event_key == "inbox:" <> capture_id,
         true <- is_binary(body) and String.valid?(body) and String.length(body) in 1..10_000,
         {:ok, _actor} <- current_proposer(config.descriptor["actor_id"]) do
      id = Ecto.UUID.generate()

      context = %{
        "inbox" => Map.take(stored.payload, ["id", "capture_id", "body"]),
        "source" => %{"event_id" => stored.id, "event_key" => stored.event_key},
        "hook" => config.descriptor,
        "charter" => Config.charter()
      }

      sql(
        """
        INSERT INTO agent_hook_runs
          (id, run_key, event_id, event_key, inbox_item_id, hook_id, hook_version,
           actor_id, config_digest, charter_digest, context_digest, context)
        VALUES ($1, $2, $3, $4, $5, 'inbox-triage', 1, $6, $7, $8, $9, $10)
        """,
        [
          uuid(id),
          run_key,
          uuid(stored.id),
          stored.event_key,
          uuid(inbox_id),
          uuid(config.descriptor["actor_id"]),
          config.digest,
          Config.charter_digest(),
          Config.digest(context),
          context
        ]
      )

      sql("INSERT INTO agent_hook_deliveries (run_id) VALUES ($1)", [uuid(id)])

      case Oban.insert(Worker.new(%{"run_id" => id})) do
        {:ok, _job} -> id
        {:error, error} -> Repo.rollback(error)
      end
    else
      _ -> Repo.rollback(:invalid_capture_or_proposer)
    end
  end

  def claim(id) do
    # AUTHORIZATION: opaque run IDs resolve only persisted hook inputs; current configuration and grants gate computation.
    Repo.transaction(fn ->
      registry_lock()

      with {:ok, run} <- load_run(id), %Delivery{} = delivery <- lock_delivery(id) do
        cond do
          delivery.completed_at ->
            {:terminal, :already_completed}

          delivery.claimed_until &&
              DateTime.compare(delivery.claimed_until, DateTime.utc_now()) == :gt ->
            {:busy, max(DateTime.diff(delivery.claimed_until, DateTime.utc_now()), 1)}

          true ->
            token = Ecto.UUID.generate()

            case eligible(run) do
              {:ok, config, actor} ->
                lease =
                  DateTime.add(
                    DateTime.utc_now(),
                    div(config.descriptor["timeout_ms"] + 999, 1_000) + 60,
                    :second
                  )

                sql(
                  "UPDATE agent_hook_deliveries SET claim_id = $2, claimed_until = $3, attempts = attempts + 1, updated_at = now() WHERE run_id = $1",
                  [uuid(id), uuid(token), lease]
                )

                {:claimed, run, token, config, actor}

              {:error, reason} ->
                record_terminal(run, :refused, nil, Atom.to_string(reason))
                {:terminal, reason}
            end
        end
      else
        _ -> Repo.rollback(:unknown_run)
      end
    end)
  end

  def finish(id, token, result) do
    # AUTHORIZATION: a leased immutable run licenses one audit outcome; only a revalidated proposer may submit a recommendation.
    Repo.transaction(fn ->
      registry_lock()

      with {:ok, run} <- load_run(id),
           %Delivery{} = delivery <- lock_delivery(id),
           :ok <- valid_claim(delivery, token) do
        case eligible(run) do
          {:ok, _config, actor} -> finish_eligible(run, token, result, actor)
          {:error, reason} -> record_terminal(run, :refused, nil, Atom.to_string(reason))
        end
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:unknown_run)
      end
    end)
    |> case do
      {:ok, {:proposal, proposal, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, proposal}

      other ->
        other
    end
  rescue
    _error in [Postgrex.Error, Ash.Error.Unknown] -> {:error, :result_persistence_failed}
  end

  defp finish_eligible(run, token, {:ok, proposal}, actor) do
    case Proposal.validate(proposal) do
      :ok ->
        Authz.with_actor(actor, fn ->
          case Authz.create_with_notifications(
                 TriageResult,
                 %{run_id: run.id, claim_id: token, proposal: proposal},
                 action: :submit
               ) do
            {:ok, result, notifications} -> {:proposal, result, notifications}
            {:error, error} -> Repo.rollback(error)
          end
        end)

      {:error, reason} ->
        record_terminal(run, :failed, nil, reason)
    end
  end

  defp finish_eligible(run, _token, {:error, reason}, _actor),
    do: record_terminal(run, :failed, nil, safe_reason(reason))

  defp finish_eligible(run, _token, _result, _actor),
    do: record_terminal(run, :failed, nil, "malformed_handler_result")

  # Called inside the Ash create transaction, including for direct Ash callers.
  # It locks and revalidates the decision before data-layer persistence.
  def prepare_submission(changeset, actor) do
    registry_lock()
    id = Ash.Changeset.get_attribute(changeset, :run_id)
    token = Ash.Changeset.get_argument(changeset, :claim_id)

    with {:ok, run} <- load_run(id),
         %Delivery{} = delivery <- lock_delivery(id),
         :ok <- valid_claim(delivery, token),
         {:ok, _config, current} <- eligible(run),
         %Actor{id: actor_id} <- actor,
         true <- actor_id == current.id do
      changeset
      |> Ash.Changeset.force_change_attribute(:actor_id, current.id)
      |> Ash.Changeset.force_change_attribute(:context_digest, run.context_digest)
      |> Ash.Changeset.force_change_attribute(
        :proposal_digest,
        Config.digest(Ash.Changeset.get_attribute(changeset, :proposal))
      )
    else
      _ ->
        Ash.Changeset.add_error(changeset,
          field: :run_id,
          message: "triage submission is unauthorized, stale, or no longer leased"
        )
    end
  end

  def complete_delivery(id) do
    sql(
      "UPDATE agent_hook_deliveries SET completed_at = now(), claim_id = NULL, claimed_until = NULL, updated_at = now() WHERE run_id = $1",
      [uuid(id)]
    )

    :ok
  end

  defp record_terminal(run, outcome, proposal, reason) do
    sql(
      """
      INSERT INTO inbox_triage_results
        (id, run_id, actor_id, context_digest, outcome, proposal, reason)
      VALUES ($1, $2, $3, $4, $5, $6, $7)
      """,
      [
        uuid(Ecto.UUID.generate()),
        uuid(run.id),
        uuid(run.actor_id),
        run.context_digest,
        Atom.to_string(outcome),
        proposal,
        reason
      ]
    )

    complete_delivery(run.id)
    outcome
  end

  defp eligible(run) do
    with {:ok, config} <- Config.current(),
         true <-
           run.config_digest == config.digest and run.charter_digest == Config.charter_digest() and
             run.context_digest == Config.digest(run.context),
         {:ok, actor} <- current_proposer(run.actor_id),
         :ok <- pending_capture(run) do
      {:ok, config, actor}
    else
      {:error, :invalid_proposer} -> {:error, :proposer_revoked_or_overprivileged}
      {:error, :stale_capture} -> {:error, :stale_capture}
      _ -> {:error, :hook_configuration_changed_or_disabled}
    end
  end

  defp pending_capture(run) do
    case sql("SELECT capture_id, body, state FROM inbox_items WHERE id = $1 FOR UPDATE", [
           uuid(run.inbox_item_id)
         ]).rows do
      [[capture_id, body, "pending"]] ->
        if %{"id" => run.inbox_item_id, "capture_id" => capture_id, "body" => body} ==
             run.context["inbox"], do: :ok, else: {:error, :stale_capture}

      _ ->
        {:error, :stale_capture}
    end
  end

  defp current_proposer(id) do
    # Registry reads are internal authorization inputs, never subject to the policy they decide.
    with {:ok, %Actor{} = actor} <- Ash.get(Actor, id, authorize?: false),
         true <- Actor.active?(actor) and Scope.holds?(actor, :proposer, :global),
         true <- Enum.all?(Scope.summary(actor), &(&1.role in [:reader, :proposer])) do
      {:ok, actor}
    else
      _ -> {:error, :invalid_proposer}
    end
  end

  defp valid_claim(%Delivery{completed_at: nil, claim_id: token, claimed_until: until}, token)
       when is_binary(token) and not is_nil(until) do
    if DateTime.compare(until, DateTime.utc_now()) == :gt, do: :ok, else: {:error, :expired_claim}
  end

  defp valid_claim(_, _), do: {:error, :stale_claim}

  defp load_run(id) do
    with {:ok, ^id} <- Ecto.UUID.cast(id),
         {:ok, %Run{} = run} <- Ash.get(Run, id, authorize?: false),
         do: {:ok, run},
         else: (_ -> {:error, :unknown_run})
  end

  defp lock_delivery(id) do
    # AUTHORIZATION: internal bookkeeping is bounded by the already-resolved immutable run ID.
    Repo.one(from(d in Delivery, where: d.run_id == ^id, lock: "FOR UPDATE"))
  end

  defp registry_lock,
    do: sql("SELECT pg_advisory_xact_lock(hashtext($1))", ["sprucegoose:actor-registry-write"])

  defp uuid(id), do: Ecto.UUID.dump!(id)
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "handler_failed"

  defp sql(statement, params) do
    # AUTHORIZATION: callers serialize and bound access to a persisted run; proposal effects also pass the Ash proposer action.
    Repo.query!(statement, params)
  end
end
