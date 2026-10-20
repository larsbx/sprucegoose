defmodule SpruceGoose.Kernel.TaskProjector do
  @moduledoc "Deterministically rebuilds the authoritative task projection from certified history."

  alias SpruceGoose.Actors.Scope
  alias SpruceGoose.Kernel.{Canonical, ContentID, Locks}
  alias SpruceGoose.{Authz, Repo}

  @projection_id "sprucegoose-authoritative-tasks-v1"
  @legacy_stream "authority:sprucegoose"
  @task_commands ~w(acknowledge_sop add_task instantiate_task link_task move_task record_artifact_receipt transition_task unlink_task update_task_metadata)
  @fields ~w(artifact_receipts artifact_requirements assignees blueprint_revision_id board_id board_revision column_id custom_fields definition_key definition_of_done description due_at id labels lock_version priority rank sop_digest sop_gate_required sop_id sop_path sop_version state task_type title workflow_id)

  def rebuild do
    with :ok <- authorize_admin() do
      # AUTHORIZATION: the global-admin gate owns the complete rebuild transaction.
      case Repo.transaction(fn -> rebuild_transaction() end) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def status do
    # AUTHORIZATION: only a global admin may compare certified and live task projections.
    with :ok <- authorize_admin(),
         {:ok, %{rows: [[position, state, digest, form_name]]}} <-
           Repo.query(
             "SELECT stream_position, state, state_digest, canonical_form FROM replay_projections WHERE projection_id = $1",
             [@projection_id]
           ),
         {:ok, form} <- Canonical.form_from_name(form_name),
         {:ok, live} <- live_state(),
         {:ok, live_digest} <- digest(live),
         {:ok, stored_digest} <- digest(state, form) do
      {:ok,
       %{
         projection_id: @projection_id,
         stream_position: position,
         projected_digest: digest,
         live_digest: live_digest,
         integrity: stored_digest == digest,
         parity: state == live and stored_digest == digest,
         differences: differences(state, live),
         lag: current_position() - position
       }}
    else
      {:ok, %{rows: []}} -> {:error, :projection_not_built}
      {:error, reason} -> {:error, reason}
    end
  end

  # Authority history is partitioned per project (D-2). Replay reads every
  # `authority:` stream except the kernel's own, in global sequence order, and
  # requires each stream's positions to be contiguous. The stored position is
  # the last global sequence consumed.
  @authority_prefix "authority:"
  @kernel_stream "authority:kernel"

  defp rebuild_transaction do
    Locks.acquire(@legacy_stream)

    # AUTHORIZATION: rebuild/0 gates these bounded reads of accepted baseline and certified history.
    with {:ok, %{rows: [[baseline, accepted_at, accepted_event]]}} <-
           Repo.query(
             "SELECT snapshot, acceptance_stream_position, accepted_event_digest FROM grandfathered_baselines WHERE baseline_id = 'grandfathered-baseline-v1'"
           ),
         # AUTHORIZATION: the same global-admin gate covers locating the acceptance event.
         {:ok, %{rows: [[accepted_sequence]]}} <-
           Repo.query("SELECT sequence FROM certified_events WHERE identity_digest = $1", [
             accepted_event
           ]),
         # AUTHORIZATION: the same global-admin gate covers the ordered event read.
         {:ok, %{rows: events}} <-
           Repo.query(
             """
             SELECT sequence, stream, stream_position, event_type, payload FROM certified_events
             WHERE stream LIKE $1 AND stream <> $2 AND sequence > $3 ORDER BY sequence
             """,
             [@authority_prefix <> "%", @kernel_stream, accepted_sequence]
           ),
         {:ok, initial} <- baseline_state(baseline),
         {:ok, state, position} <-
           replay(initial, accepted_sequence, %{@legacy_stream => accepted_at}, events),
         {:ok, digest} <- digest(state),
         :ok <- store(position, state, digest) do
      %{
        projection_id: @projection_id,
        stream_position: position,
        state_digest: digest,
        tasks: map_size(state["tasks"])
      }
    else
      {:ok, %{rows: []}} -> Repo.rollback(:baseline_not_accepted)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp baseline_state(%{"tables" => %{"workflow_tasks" => rows}}) when is_list(rows) do
    tasks =
      Map.new(rows, fn row ->
        task = normalize(row)
        {task["id"], task}
      end)

    {:ok, %{"schema" => @projection_id, "tasks" => tasks}}
  end

  defp baseline_state(_), do: {:error, :invalid_baseline_projection}

  defp replay(state, sequence, positions, events) do
    events
    |> Enum.reduce_while({:ok, state, sequence, positions}, fn
      [seq, stream, position, type, payload], {:ok, acc, _seq, seen} ->
        if position != Map.get(seen, stream, 0) + 1 do
          {:halt, {:error, :noncontiguous_certified_history}}
        else
          case apply_event(type, payload, acc) do
            {:ok, acc} -> {:cont, {:ok, acc, seq, Map.put(seen, stream, position)}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end
    end)
    |> case do
      {:ok, state, sequence, _positions} -> {:ok, state, sequence}
      error -> error
    end
  end

  defp apply_event("MutationAccepted", %{"command" => command, "result" => result}, acc)
       when command in @task_commands and is_map(result) do
    case normalize(result) do
      %{"id" => id} = task when is_binary(id) and id != "" ->
        {:ok, put_in(acc, ["tasks", id], task)}

      _invalid_task ->
        {:error, :unsupported_certified_event}
    end
  end

  defp apply_event("MutationAccepted", %{"command" => command}, _acc)
       when command in @task_commands,
       do: {:error, :unsupported_certified_event}

  defp apply_event("MutationAccepted", %{"command" => command, "result" => result}, acc)
       when is_binary(command) and is_map(result),
       do: {:ok, acc}

  defp apply_event(type, payload, acc)
       when is_binary(type) and is_map(payload) and type != "MutationAccepted",
       do: {:ok, acc}

  defp apply_event(_type, _payload, _acc), do: {:error, :unsupported_certified_event}

  defp normalize(row) do
    row =
      if Map.has_key?(row, "type"),
        do: row |> Map.put("task_type", row["type"]) |> Map.delete("type"),
        else: row

    row = if is_binary(row["task_id"]), do: Map.put(row, "id", row["task_id"]), else: row

    Map.take(row, @fields)
  end

  defp live_state do
    sql =
      "SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.id), '[]'::jsonb) FROM workflow_tasks t"

    # AUTHORIZATION: status/0 established global-admin authority before this bounded parity read.
    case Repo.query(sql) do
      {:ok, %{rows: [[rows]]}} ->
        tasks =
          Map.new(rows, fn row ->
            task = normalize(row)
            {task["id"], task}
          end)

        {:ok, %{"schema" => @projection_id, "tasks" => tasks}}

      _ ->
        {:error, :live_projection_unavailable}
    end
  end

  defp store(position, state, digest) do
    # AUTHORIZATION: rebuild/0 gates this transaction-local projector capability.
    Repo.query!("SELECT set_config('sprucegoose.projector_write', 'on', true)")

    # AUTHORIZATION: this is the sole projector-owned materialization write path.
    result =
      case Repo.query(
             """
               INSERT INTO replay_projections (projection_id, stream_position, state, state_digest, canonical_form)
               VALUES ($1, $2, $3::jsonb, $4, $5)
               ON CONFLICT (projection_id) DO UPDATE SET stream_position = EXCLUDED.stream_position,
                 state = EXCLUDED.state, state_digest = EXCLUDED.state_digest,
                 canonical_form = EXCLUDED.canonical_form, updated_at = now()
             """,
             [@projection_id, position, state, digest, Canonical.form_name(:jcs)]
           ) do
        {:ok, _} -> :ok
        _ -> {:error, :projection_store_unavailable}
      end

    # AUTHORIZATION: close the narrowly scoped projector capability before returning.
    Repo.query!("SELECT set_config('sprucegoose.projector_write', 'off', true)")
    result
  end

  defp digest(state, form \\ :jcs) do
    with {:ok, bytes} <- Canonical.encode(state, form),
         {:ok, %ContentID{digest: digest}} <- ContentID.derive(:sha256, bytes),
         do: {:ok, digest}
  end

  defp current_position do
    # AUTHORIZATION: status/0 established global-admin authority for this lag measurement.
    Repo.query!(
      "SELECT COALESCE(max(sequence), 0) FROM certified_events WHERE stream LIKE $1 AND stream <> $2",
      [@authority_prefix <> "%", @kernel_stream]
    ).rows
    |> hd()
    |> hd()
  end

  defp differences(%{"tasks" => projected}, %{"tasks" => live}) do
    (Map.keys(projected) ++ Map.keys(live))
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      if projected[id] == live[id] do
        []
      else
        fields =
          (Map.keys(projected[id] || %{}) ++ Map.keys(live[id] || %{}))
          |> Enum.uniq()
          |> Enum.filter(&(get_in(projected, [id, &1]) != get_in(live, [id, &1])))
          |> Enum.sort()

        [%{id: id, fields: fields}]
      end
    end)
    |> Enum.sort()
  end

  defp authorize_admin do
    if Scope.holds?(Authz.actor!(), :admin, :global),
      do: :ok,
      else: {:error, "task projection requires admin at global scope"}
  end
end
