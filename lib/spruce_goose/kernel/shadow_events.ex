defmodule SpruceGoose.Kernel.ShadowEvents do
  @moduledoc "Transactional certified-event shadow for the baseline replay scope."

  alias SpruceGoose.Kernel.{Canonical, CertifiedEvent, ContentID}
  alias SpruceGoose.Kernel.Postgres.EventLedger
  alias SpruceGoose.Repo

  @policy "kernel/shadow-event-roots.json"
  @notifications_key :spruce_goose_shadow_notifications
  @shadowed_verbs [
    :acknowledge_sop,
    :add_board,
    :add_column,
    :add_dependency,
    :add_filter,
    :add_task,
    :add_todo,
    :add_todo_dependency,
    :admit_derivation,
    :apply_blueprint,
    :complete_todo,
    :instantiate_task,
    :link_task,
    :move_task,
    :record_artifact_receipt,
    :remove_board,
    :remove_column,
    :remove_dependency,
    :remove_filter,
    :remove_todo,
    :remove_todo_dependency,
    :rename_board,
    :rename_column,
    :transition_task,
    :unlink_task,
    :update_task_metadata
  ]

  def transaction(command, fun) when is_function(fun, 0) do
    previous = Process.put(@notifications_key, [])

    try do
      # AUTHORIZATION: Executor resolves the actor before entering this transaction; all dispatch writes remain actor-bound.
      case Repo.transaction(fn -> run(command, fun) end) do
        {:ok, result} ->
          @notifications_key
          |> Process.get([])
          |> Enum.reverse()
          |> List.flatten()
          |> Ash.Notifier.notify()

          result

        {:error, reason} ->
          {:error, reason}
      end
    after
      if is_nil(previous),
        do: Process.delete(@notifications_key),
        else: Process.put(@notifications_key, previous)
    end
  end

  def collecting_notifications?, do: is_list(Process.get(@notifications_key))

  def collect_notifications(notifications) when is_list(notifications) do
    Process.put(@notifications_key, [notifications | Process.get(@notifications_key, [])])
    :ok
  end

  def status do
    # AUTHORIZATION: Executor resolves the caller before this bounded reconciliation read.
    with {:ok, %{rows: [[total, missing, malformed_streams]]}} <-
           Repo.query("""
           WITH covered AS (
             SELECT payload->'result'->>'id' AS task_id,
                    min((payload->'result'->>'lock_version')::bigint) AS first_lock
             FROM certified_events
             WHERE payload->>'outbox_event_key' IS NOT NULL
             GROUP BY payload->'result'->>'id'
           ), missing AS (
             SELECT count(*) AS count
             FROM outbox_events o
             JOIN covered c ON c.task_id = o.aggregate_id
             WHERE o.aggregate_type = 'task'
               AND split_part(o.event_key, ':', 3)::bigint >= c.first_lock
               AND NOT EXISTS (
                 SELECT 1 FROM certified_events c
                 WHERE c.payload->>'outbox_event_key' = o.event_key
               )
           ), malformed AS (
             SELECT count(*) AS count
             FROM (
               SELECT stream, count(*) AS rows, min(stream_position) AS first,
                      max(stream_position) AS last,
                      count(DISTINCT stream_position) AS distinct_positions
               FROM certified_events GROUP BY stream
             ) streams
             WHERE first <> 1 OR last <> rows OR distinct_positions <> rows
           )
           SELECT (SELECT count(*) FROM certified_events), missing.count, malformed.count
           FROM missing, malformed
           """) do
      {:ok,
       %{
         certified_events: total,
         missing_task_events: missing,
         malformed_streams: malformed_streams,
         reconciled: missing == 0 and malformed_streams == 0
       }}
    else
      _ -> {:error, :shadow_reconciliation_unavailable}
    end
  end

  def shadowed?(command) when is_tuple(command) and tuple_size(command) > 0,
    do: elem(command, 0) in @shadowed_verbs

  def shadowed?(_command), do: false

  defp run(command, fun) do
    case fun.() do
      {:ok, result} = accepted ->
        with {:ok, payload} <- payload(command, result),
             {:ok, roots} <- roots(),
             {:ok, idempotency_key} <- idempotency_key(payload),
             {:ok, event} <-
               CertifiedEvent.new(%{
                 stream: "authority:sprucegoose",
                 event_type: "MutationAccepted",
                 idempotency_key: idempotency_key,
                 payload: payload,
                 roots: roots
               }),
             {:ok, _identity, _ledger} <- EventLedger.append(EventLedger.new(), event) do
          accepted
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp payload(command, result) do
    with {:ok, normalized} <- result |> json_result() |> Jason.encode() |> decode_json() do
      outbox_key = outbox_event_key(normalized)

      {:ok,
       %{
         "command" => command |> elem(0) |> Atom.to_string(),
         "outbox_event_key" => outbox_key,
         "result" => normalized,
         "shadow_schema" => "sprucegoose-mutation-shadow-v1"
       }}
    end
  end

  defp decode_json({:ok, bytes}), do: Jason.decode(bytes)
  defp decode_json({:error, _error}), do: {:error, :noncanonical_shadow_result}

  defp json_result(%_{} = result) do
    result
    |> Map.from_struct()
    |> Map.drop([
      :__lateral_join_source__,
      :__meta__,
      :__metadata__,
      :__order__,
      :aggregates,
      :calculations,
      :task
    ])
  end

  defp json_result(result), do: result

  defp outbox_event_key(%{"id" => id, "lock_version" => _lock, "board_revision" => _board}) do
    # AUTHORIZATION: the actor-bound mutation has completed in this transaction; this binds its trigger-created outbox identity.
    case Repo.query(
           """
           SELECT event_key FROM outbox_events
           WHERE aggregate_type = 'task' AND aggregate_id = $1
           ORDER BY inserted_at DESC, event_key DESC LIMIT 1
           """,
           [id]
         ) do
      {:ok, %{rows: [[event_key]]}} -> event_key
      _ -> nil
    end
  end

  defp outbox_event_key(_result), do: nil

  defp roots do
    path =
      Application.get_env(
        :spruce_goose,
        :shadow_event_policy_path,
        Application.app_dir(:spruce_goose, "priv/#{@policy}")
      )

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"schema" => "sprucegoose-shadow-event-roots-v1", "roots" => roots}} <-
           Jason.decode(bytes) do
      {:ok, roots}
    else
      _ -> {:error, :shadow_roots_unavailable}
    end
  end

  defp idempotency_key(payload) do
    with {:ok, bytes} <- Canonical.encode(payload),
         {:ok, %ContentID{digest: digest}} <- ContentID.derive(:sha256, bytes) do
      {:ok, "shadow:" <> digest}
    end
  end
end
