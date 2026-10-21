defmodule SpruceGoose.Kernel.LedgerExport do
  @moduledoc """
  The certified ledger in a form that leaves the database.

  `export/1` writes every certified event, in global sequence order, as one
  JSON object per line. An event in the `jcs-v1` form carries everything a
  reader needs to recompute its identity with any JSON implementation;
  `scripts/verify-certified-ledger.py` does so without the BEAM. Events in the
  legacy `etf-v1` form are exported with their original identity and, once
  `rekey/0` has run, the `jcs-v1` identity the re-rooting record assigns them.

  `rekey/0` is the one-time re-rooting transaction: for every `etf-v1` event
  it records the pair (original identity, JCS identity) in an immutable table
  and appends a single `CanonicalFormAdopted` event naming the record's digest.
  It changes no existing row and runs at most once.
  """

  alias SpruceGoose.Actors.Scope
  alias SpruceGoose.Kernel.{Canonical, CertifiedEvent, ContentID, ShadowEvents}
  alias SpruceGoose.Kernel.Postgres.EventLedger
  alias SpruceGoose.{Authz, Repo}

  @schema "sprucegoose-certified-ledger-export-v1"
  @kernel_stream "authority:kernel"

  def schema, do: @schema

  @doc "Write the whole certified ledger to `path` as JSONL. Refuses to overwrite."
  def export(path) when is_binary(path) do
    with :ok <- authorize_admin(),
         :ok <- writable_target(path),
         {:ok, rows} <- rows() do
      lines = Enum.map(rows, &(&1 |> line() |> Jason.encode!()))
      header = Jason.encode!(%{"schema" => @schema, "events" => length(rows)})
      File.write!(path, Enum.join([header | lines], "\n") <> "\n", [:exclusive])
      File.chmod!(path, 0o600)
      {:ok, %{path: path, events: length(rows), schema: @schema}}
    end
  end

  @doc "Record the JCS identity of every legacy event, once."
  def rekey do
    with :ok <- authorize_admin() do
      # AUTHORIZATION: the global-admin gate above owns the whole re-rooting transaction.
      case Repo.transaction(fn -> rekey_transaction() end) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp rekey_transaction do
    SpruceGoose.Kernel.Locks.acquire(@kernel_stream)

    # AUTHORIZATION: rekey/0 gated this read; legacy rows are immutable.
    with {:ok, %{rows: [[0]]}} <- Repo.query("SELECT count(*) FROM certified_event_rekeys"),
         {:ok, %{rows: legacy}} <-
           Repo.query("""
           SELECT sequence, stream, event_type, idempotency_key, payload, roots, identity_digest
           FROM certified_events WHERE canonical_form = 'etf-v1' ORDER BY sequence
           """),
         {:ok, pairs} <- jcs_identities(legacy),
         :ok <- insert_pairs(pairs),
         {:ok, roots} <- ShadowEvents.roots(),
         {:ok, record_digest} <- record_digest(pairs),
         {:ok, event} <- adoption_event(pairs, record_digest, roots),
         {:ok, identity, _} <- EventLedger.append(EventLedger.new(), event) do
      %{rekeyed: length(pairs), record_digest: record_digest, adoption_event: identity.digest}
    else
      {:ok, %{rows: [[_]]}} -> Repo.rollback(:already_rekeyed)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp jcs_identities(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn [seq, stream, type, key, payload, roots, etf],
                                          {:ok, acc} ->
      attrs = %{
        stream: stream,
        event_type: type,
        idempotency_key: key,
        payload: payload,
        roots: roots
      }

      case CertifiedEvent.new(attrs, :jcs) do
        {:ok, %CertifiedEvent{identity: %ContentID{digest: jcs}}} ->
          {:cont, {:ok, [{seq, etf, jcs} | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:unrekeyable_event, seq, reason}}}
      end
    end)
    |> then(fn
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      error -> error
    end)
  end

  defp insert_pairs(pairs) do
    Enum.reduce_while(pairs, :ok, fn {seq, etf, jcs}, :ok ->
      # AUTHORIZATION: rekey/0 gated this insert into the immutable re-rooting record.
      case Repo.query(
             "INSERT INTO certified_event_rekeys (sequence, identity_digest, jcs_digest) VALUES ($1, $2, $3)",
             [seq, etf, jcs]
           ) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp record_digest(pairs) do
    with {:ok, bytes} <-
           Canonical.encode(Enum.map(pairs, fn {seq, etf, jcs} -> [seq, etf, jcs] end)),
         {:ok, %ContentID{digest: digest}} <- ContentID.derive(:sha256, bytes),
         do: {:ok, digest}
  end

  defp adoption_event(pairs, record_digest, roots) do
    CertifiedEvent.new(%{
      stream: @kernel_stream,
      event_type: "CanonicalFormAdopted",
      idempotency_key: "canonical-form:jcs-v1",
      payload: %{
        "adopted_form" => Canonical.form_name(:jcs),
        "legacy_form" => Canonical.form_name(:etf),
        "rekeyed_events" => length(pairs),
        "record_content_id" => "sha256:" <> record_digest,
        "actor" => Authz.attribution()
      },
      roots: roots
    })
  end

  defp rows do
    # AUTHORIZATION: export/1 gated this read of the immutable ledger and its re-rooting record.
    case Repo.query("""
         SELECT e.sequence, e.stream, e.stream_position, e.event_type, e.idempotency_key,
                e.payload, e.roots, e.canonical_form, e.identity_digest, r.jcs_digest
         FROM certified_events e
         LEFT JOIN certified_event_rekeys r ON r.identity_digest = e.identity_digest
         ORDER BY e.sequence
         """) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, _} -> {:error, :ledger_unavailable}
    end
  end

  defp line([seq, stream, position, type, key, payload, roots, form, identity, jcs]) do
    %{
      "sequence" => seq,
      "stream" => stream,
      "stream_position" => position,
      "event_type" => type,
      "idempotency_key" => key,
      "payload" => payload,
      "roots" => roots,
      "canonical_form" => form,
      "identity" => "sha256:" <> identity,
      "jcs_identity" =>
        if(form == "jcs-v1", do: "sha256:" <> identity, else: jcs && "sha256:" <> jcs)
    }
  end

  defp writable_target(path) do
    cond do
      Path.type(path) != :absolute -> {:error, "export path must be absolute"}
      File.exists?(path) -> {:error, "export path already exists; refusing to overwrite"}
      not File.dir?(Path.dirname(path)) -> {:error, "export directory does not exist"}
      true -> :ok
    end
  end

  defp authorize_admin do
    if Scope.holds?(Authz.actor!(), :admin, :global),
      do: :ok,
      else: {:error, "certified ledger export and rekey require admin at global scope"}
  end
end
