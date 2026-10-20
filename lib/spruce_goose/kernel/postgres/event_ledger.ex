defmodule SpruceGoose.Kernel.Postgres.EventLedger do
  @moduledoc "PostgreSQL EventLedger adapter for immutable shadow history."

  @behaviour SpruceGoose.Kernel.EventLedger

  alias SpruceGoose.Kernel.{Canonical, CertifiedEvent, ContentID}
  alias SpruceGoose.Repo

  @required_roots ~w(ontology schema norm policy grant_epoch agent_charter interpreter evidence_policy)
  @sha256 ~r/\A[0-9a-f]{64}\z/

  defstruct []

  def new, do: %__MODULE__{}

  @impl true
  def append(%__MODULE__{} = ledger, %CertifiedEvent{} = event) do
    with :ok <- required_roots(event.roots),
         :ok <- ContentID.verify(event.identity, event.canonical_bytes) do
      # AUTHORIZATION: this internal adapter accepts only a pre-certified event; no CLI calls it directly.
      case Repo.transaction(fn -> append_transaction(event) end) do
        {:ok, %ContentID{} = identity} -> {:ok, identity, ledger}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def read(%__MODULE__{}, stream) when is_binary(stream) and stream != "" do
    # AUTHORIZATION: this internal adapter exposes certified history only to its authorized caller.
    case Repo.query(
           """
           SELECT event_type, idempotency_key, payload, roots, canonical_bytes,
                  identity_algorithm, identity_digest, canonical_form
           FROM certified_events
           WHERE stream = $1
           ORDER BY stream_position
           """,
           [stream]
         ) do
      {:ok, %{rows: rows}} -> decode_rows(stream, rows)
      {:error, _error} -> {:error, :ledger_unavailable}
    end
  end

  @impl true
  def streams(%__MODULE__{}) do
    # AUTHORIZATION: this internal adapter lists stream names only, for export and projection.
    case Repo.query("SELECT DISTINCT stream FROM certified_events ORDER BY stream") do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, &hd/1)}
      {:error, _error} -> {:error, :ledger_unavailable}
    end
  end

  @impl true
  def verify(%__MODULE__{}, %ContentID{algorithm: :sha256, digest: digest} = identity) do
    # AUTHORIZATION: this internal verifier reads one immutable certified-event row by content identity.
    case Repo.query(
           """
           SELECT canonical_bytes
           FROM certified_events
           WHERE identity_algorithm = 'sha256' AND identity_digest = $1
           """,
           [digest]
         ) do
      {:ok, %{rows: [[bytes]]}} -> ContentID.verify(identity, bytes)
      {:ok, %{rows: []}} -> verify_rekeyed(identity)
      _ -> {:error, :ledger_unavailable}
    end
  end

  def verify(%__MODULE__{}, %ContentID{}), do: {:error, :unsupported_algorithm}

  # A jcs-v1 identity for an event written in etf-v1 is honoured through the
  # re-rooting record: the row's stored bytes must still hash to its original
  # identity, and its content re-encoded as JCS must hash to the one asked for.
  defp verify_rekeyed(%ContentID{digest: jcs_digest} = identity) do
    # AUTHORIZATION: internal verifier; the re-rooting record is immutable.
    case Repo.query(
           """
           SELECT e.stream, e.event_type, e.idempotency_key, e.payload, e.roots,
                  e.canonical_bytes, e.identity_digest
           FROM certified_event_rekeys r
           JOIN certified_events e ON e.identity_digest = r.identity_digest
           WHERE r.jcs_digest = $1
           """,
           [jcs_digest]
         ) do
      {:ok, %{rows: [[stream, type, key, payload, roots, bytes, etf_digest]]}} ->
        attrs = %{
          stream: stream,
          event_type: type,
          idempotency_key: key,
          payload: payload,
          roots: roots
        }

        with :ok <- ContentID.verify(%ContentID{algorithm: :sha256, digest: etf_digest}, bytes),
             {:ok, %CertifiedEvent{identity: ^identity}} <- CertifiedEvent.new(attrs, :jcs) do
          :ok
        else
          _ -> {:error, :content_mismatch}
        end

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      _ ->
        {:error, :ledger_unavailable}
    end
  end

  defp append_transaction(event) do
    # AUTHORIZATION: the caller supplied a verified certified event; this lock serializes its stream only.
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [event.stream])

    # AUTHORIZATION: idempotency is checked inside the same serialized append transaction.
    case Repo.query!(
           """
           SELECT identity_algorithm, identity_digest, canonical_bytes
           FROM certified_events
           WHERE stream = $1 AND idempotency_key = $2
           """,
           [event.stream, event.idempotency_key]
         ).rows do
      [["sha256", digest, bytes]] ->
        if digest == event.identity.digest and bytes == event.canonical_bytes,
          do: event.identity,
          else: Repo.rollback(:idempotency_conflict)

      [] ->
        insert(event)
    end
  end

  defp insert(event) do
    # AUTHORIZATION: this is the sole adapter insert; PostgreSQL constraints enforce identity and roots.
    %{rows: [[digest]]} =
      Repo.query!(
        """
        INSERT INTO certified_events (
          stream, stream_position, event_type, idempotency_key, payload, roots,
          canonical_bytes, identity_algorithm, identity_digest, canonical_form
        )
        SELECT $1, COALESCE(max(stream_position), 0) + 1, $2, $3, $4::jsonb,
               $5::jsonb, $6, 'sha256', $7, $8
        FROM certified_events
        WHERE stream = $1
        RETURNING identity_digest
        """,
        [
          event.stream,
          event.event_type,
          event.idempotency_key,
          event.payload,
          event.roots,
          event.canonical_bytes,
          event.identity.digest,
          Canonical.form_name(event.canonical_form)
        ]
      )

    %ContentID{algorithm: :sha256, digest: digest}
  end

  defp decode_rows(stream, rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      [event_type, idempotency_key, payload, roots, bytes, "sha256", digest, form_name],
      {:ok, events} ->
        attrs = %{
          stream: stream,
          event_type: event_type,
          idempotency_key: idempotency_key,
          payload: payload,
          roots: roots
        }

        with {:ok, form} <- Canonical.form_from_name(form_name),
             {:ok, event} <- CertifiedEvent.new(attrs, form) do
          {:ok, event}
        end
        |> case do
          {:ok, %CertifiedEvent{canonical_bytes: ^bytes, identity: %{digest: ^digest}} = event} ->
            {:cont, {:ok, [event | events]}}

          _ ->
            {:halt, {:error, :corrupt_event}}
        end

      _, _acc ->
        {:halt, {:error, :corrupt_event}}
    end)
    |> then(fn
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end)
  end

  defp required_roots(roots) do
    Enum.find_value(@required_roots, :ok, fn root ->
      case Map.fetch(roots, root) do
        {:ok, "sha256:" <> digest} ->
          if Regex.match?(@sha256, digest), do: false, else: {:error, {:invalid_root, root}}

        {:ok, _invalid} ->
          {:error, {:invalid_root, root}}

        :error ->
          {:error, {:missing_root, root}}
      end
    end)
  end
end
