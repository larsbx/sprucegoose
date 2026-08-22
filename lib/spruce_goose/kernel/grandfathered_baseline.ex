defmodule SpruceGoose.Kernel.GrandfatheredBaseline do
  @moduledoc "Creates the single immutable legacy projection baseline and acceptance event."

  alias SpruceGoose.Actors.Scope
  alias SpruceGoose.Kernel.{CertifiedEvent, ContentID, ShadowEvents}
  alias SpruceGoose.Kernel.Postgres.EventLedger
  alias SpruceGoose.{Authz, Repo}

  @stream "authority:sprucegoose"
  @baseline_id "grandfathered-baseline-v1"
  @tables ~w(projects roadmaps workflows workflow_blueprint_revisions workflow_tasks task_dependencies task_todos task_todo_dependencies boards board_columns saved_filters derivation_permits)
  @exclusions %{
    "classes" => [
      "authentication_credentials",
      "delivery_and_job_infrastructure",
      "test_and_dogfood_fixtures",
      "certified_history"
    ],
    "relations" =>
      ~w(users tokens oauth_refresh_tokens oauth_consents oauth_clients oauth_authorization_codes outbox_events oban_jobs certified_events),
    "rule" =>
      "only the named operational projection relations are in the baseline; no excluded row receives invented provenance"
  }

  def accept do
    with :ok <- authorize_admin() do
      # AUTHORIZATION: the global-admin check above gates the complete atomic acceptance transaction.
      case Repo.transaction(fn -> accept_transaction() end) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def show do
    with :ok <- authorize_admin(),
         # AUTHORIZATION: only a global admin may read the accepted baseline metadata.
         {:ok, %{rows: [row]}} <-
           Repo.query(
             """
             SELECT baseline_id, snapshot_digest, legacy_final_stream_position,
                    acceptance_stream_position, migration_set_sha256,
                    exclusions, accepted_event_digest
             FROM grandfathered_baselines WHERE baseline_id = $1
             """,
             [@baseline_id]
           ) do
      {:ok, summary(row)}
    else
      {:ok, %{rows: []}} -> {:error, :baseline_not_accepted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp accept_transaction do
    # AUTHORIZATION: accept/0 established a global-admin actor before entering this stream lock.
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [@stream])
    refuse_existing!()

    with {:ok, %{reconciled: true}} <- ShadowEvents.status(),
         {:ok, roots} <- ShadowEvents.roots(),
         {snapshot, bytes} <- snapshot(),
         {:ok, %ContentID{digest: snapshot_digest}} <- ContentID.derive(:sha256, bytes),
         legacy_position <- current_position(),
         {:ok, event} <- acceptance_event(snapshot_digest, legacy_position, roots),
         {:ok, identity, _ledger} <- EventLedger.append(EventLedger.new(), event),
         acceptance_position <- event_position(identity.digest),
         :ok <- require_next_position(legacy_position, acceptance_position),
         :ok <-
           insert(
             snapshot,
             bytes,
             snapshot_digest,
             legacy_position,
             acceptance_position,
             roots,
             identity.digest
           ) do
      summary([
        @baseline_id,
        snapshot_digest,
        legacy_position,
        acceptance_position,
        String.replace_prefix(roots["schema"], "sha256:", ""),
        @exclusions,
        identity.digest
      ])
    else
      {:ok, %{reconciled: false}} -> Repo.rollback(:shadow_not_reconciled)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp snapshot do
    table_pairs =
      Enum.map_join(@tables, ",\n", fn table ->
        "'#{table}', (SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text), '[]'::jsonb) FROM #{table} t)"
      end)

    sql = """
    WITH captured AS (
      SELECT jsonb_build_object(
        'schema', 'sprucegoose-grandfathered-baseline-v1',
        'tables', jsonb_build_object(#{table_pairs})
      ) AS value
    )
    SELECT value, convert_to(value::text, 'UTF8') FROM captured
    """

    # AUTHORIZATION: accept/0 gated this bounded read of the named replay projection relations.
    %{rows: [[snapshot, bytes]]} = Repo.query!(sql)
    {snapshot, bytes}
  end

  defp acceptance_event(digest, legacy_position, roots) do
    CertifiedEvent.new(%{
      stream: @stream,
      event_type: "GrandfatheredStateAccepted",
      idempotency_key: "grandfathered-baseline:" <> digest,
      payload: %{
        "baseline_id" => @baseline_id,
        "exclusions" => @exclusions,
        "legacy_final_stream_position" => legacy_position,
        "migration_set_sha256" => String.replace_prefix(roots["schema"], "sha256:", ""),
        "snapshot_content_id" => "sha256:" <> digest,
        "snapshot_schema" => "sprucegoose-grandfathered-baseline-v1"
      },
      roots: roots
    })
  end

  defp insert(snapshot, bytes, digest, legacy_position, acceptance_position, roots, event_digest) do
    migration_digest = String.replace_prefix(roots["schema"], "sha256:", "")

    # AUTHORIZATION: accept/0 gated this immutable insert; it shares the acceptance transaction.
    case Repo.query(
           """
           INSERT INTO grandfathered_baselines (
             baseline_id, snapshot, canonical_bytes, snapshot_digest,
             legacy_final_stream_position, acceptance_stream_position,
             migration_set_sha256, exclusions, accepted_event_digest
           ) VALUES ($1, $2::jsonb, $3, $4, $5, $6, $7, $8::jsonb, $9)
           """,
           [
             @baseline_id,
             snapshot,
             bytes,
             digest,
             legacy_position,
             acceptance_position,
             migration_digest,
             @exclusions,
             event_digest
           ]
         ) do
      {:ok, _result} -> :ok
      {:error, _error} -> {:error, :baseline_store_unavailable}
    end
  end

  defp refuse_existing! do
    # AUTHORIZATION: accept/0 gated this singleton check inside the serialized transaction.
    case Repo.query!("SELECT 1 FROM grandfathered_baselines WHERE baseline_id = $1", [
           @baseline_id
         ]).rows do
      [] -> :ok
      _ -> Repo.rollback(:baseline_already_accepted)
    end
  end

  defp current_position do
    # AUTHORIZATION: accept/0 gated this exact stream-boundary read under the stream lock.
    Repo.query!(
      "SELECT COALESCE(max(stream_position), 0) FROM certified_events WHERE stream = $1",
      [@stream]
    ).rows
    |> hd()
    |> hd()
  end

  defp event_position(digest) do
    # AUTHORIZATION: accept/0 gated this lookup of the event appended in the current transaction.
    Repo.query!("SELECT stream_position FROM certified_events WHERE identity_digest = $1", [
      digest
    ]).rows
    |> hd()
    |> hd()
  end

  defp require_next_position(position, next) when next == position + 1, do: :ok
  defp require_next_position(_position, _next), do: {:error, :noncontiguous_acceptance_event}

  defp authorize_admin do
    if Scope.holds?(Authz.actor!(), :admin, :global),
      do: :ok,
      else: {:error, "baseline acceptance requires admin at global scope"}
  end

  defp summary([id, digest, legacy, accepted, migration, exclusions, event]) do
    %{
      baseline_id: id,
      snapshot_digest: digest,
      legacy_final_stream_position: legacy,
      acceptance_stream_position: accepted,
      migration_set_sha256: migration,
      exclusions: exclusions,
      accepted_event_digest: event
    }
  end
end
