defmodule SpruceGoose.Review.Snapshot do
  @moduledoc """
  Build and sign the canonical review snapshot consumed by the protected
  dashboard's read adapter (`sprucegoose-review-read`).

  ## Why this exists

  The adapter must be able to report the backlog *and prove* that what it
  reported is what the authority actually holds. It therefore refuses anything
  it cannot verify: an exact key set, a signature under the peer key, a
  PostgreSQL snapshot token, and the running source identity. This module is
  the authority side of that contract.

  ## This is the first use of the peer private key

  `spruce_goose_identity` has held a keypair since the 2026-08-28 rotation and
  nothing has ever signed with it. Two consequences worth stating plainly:

    * The private half never leaves this module. It is read inside the signing
      function and not returned, logged, or placed in any struct that could be
      inspected or serialised.
    * The signature covers the *canonical JSON bytes that are transmitted*, not
      a re-encoding of them. Signing a map and encoding separately would let
      encoder differences separate what was signed from what was sent.

  ## Atomicity

  Paging is bounded at 500 rows, so a large backlog needs several
  statements. Under READ COMMITTED those statements would each see a different
  database state and the pages would not compose into one consistent backlog.
  The read therefore runs in a REPEATABLE READ transaction, and the snapshot
  token is captured inside it so the consumer can confirm every page came from
  one point in time.
  """

  alias SpruceGoose.Repo

  @schema "sprucegoose-review-snapshot-v1"
  @page_size 500

  # The states the review is defined over: everything that is not terminal.
  # Sorted, because the adapter compares this list by equality.
  @states ~w(blocked failed in_progress inbox proposed queued ready waiting)

  @envelope_schema "sprucegoose-review-envelope-v1"

  @doc """
  The full envelope the CLI returns, ready to serialise.

  The receipt carries the payload as base64 of the exact bytes that were
  signed — not a re-encoding — so a verifier that checks the digest and the
  signature is checking the same octets in both cases.
  """
  def envelope(read_fun) when is_function(read_fun, 0) do
    {:ok, {bytes, signature}} = build(read_fun)

    %{
      "ok" => true,
      "schema" => @envelope_schema,
      "receipt" => %{
        "algorithm" => "ed25519",
        "payload" => Base.encode64(bytes),
        "payload_sha256" => :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower),
        "signature" => Base.encode64(signature)
      }
    }
  end

  @doc """
  Return `{:ok, {payload_bytes, signature}}` for the current backlog.

  Deliberately returns the encoded bytes rather than the map: the signature is
  over these octets, and handing back a map would invite a caller to re-encode
  and silently break the correspondence.
  """
  def build(read_fun) when is_function(read_fun, 0) do
    # AUTHORIZATION: opens a read-only transaction for snapshot consistency and
    # reads no actor-owned data itself. The rows come from `read_fun`, which the
    # caller builds through SpruceGoose.Authz with its own actor.
    Repo.transaction(fn ->
      raise_isolation()
      snapshot = current_snapshot()
      {tasks, total} = read_fun.()

      payload = %{
        "schema" => @schema,
        "authority" => authority(),
        "source" => source(),
        "query" => %{"page_size" => @page_size, "states" => @states},
        "snapshot" => snapshot,
        "tasks" => tasks,
        "count" => length(tasks),
        "total" => total
      }

      bytes = canonical(payload)
      {bytes, sign(bytes)}
    end)
  end

  # PostgreSQL refuses SET TRANSACTION ISOLATION LEVEL once the enclosing
  # transaction has issued any statement, and the failure poisons that
  # transaction, so it cannot be attempted-and-rescued. Under the SQL sandbox
  # every test already runs inside such a transaction, so the upgrade is
  # skipped there.
  #
  # What that costs: pages are still read inside one transaction and remain
  # mutually consistent, but under the sandbox's READ COMMITTED a concurrent
  # writer could be visible between pages. Production takes this path with no
  # enclosing transaction and does get REPEATABLE READ, which is where the
  # guarantee actually matters.
  defp raise_isolation do
    sandboxed? =
      Application.get_env(:spruce_goose, Repo, [])[:pool] == Ecto.Adapters.SQL.Sandbox

    unless sandboxed? do
      # AUTHORIZATION: transaction-level setting, touches no actor-owned data.
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])
    end
  end

  # --- payload members -------------------------------------------------------

  defp authority do
    %{
      "actor" => "admin-papa",
      "kind" => "centralized-ash-postgresql",
      "peer_public_key" => Base.encode64(peer_public_key())
    }
  end

  # commit and tree come from the release the node is running, which is the
  # only honest answer to "what code produced this". module_md5 is the BEAM's
  # own digest of this module, so editing this file changes the identity even
  # if the release metadata is untouched.
  defp source do
    provenance = release_provenance()

    %{
      "commit" => provenance["source"]["commit"],
      "tree" => provenance["source"]["tree"],
      "module_md5" => module_md5()
    }
  end

  defp module_md5 do
    __MODULE__.module_info(:md5) |> Base.encode16(case: :lower)
  end

  # RELEASE_ROOT is set by the release boot script and is the only reliable
  # answer. `:code.root_dir()` points at the Erlang installation under `mix
  # run`, which is why this must not fall back to it silently: a snapshot that
  # cannot state its own source identity has to fail, not guess.
  defp release_provenance do
    root =
      System.get_env("RELEASE_ROOT") ||
        raise "RELEASE_ROOT is unset: a review snapshot can only be produced from a " <>
                "built release, because its source identity comes from the release's " <>
                "governed-provenance.json"

    path =
      Path.join([
        root,
        "releases",
        to_string(Application.spec(:spruce_goose, :vsn)),
        "governed-provenance.json"
      ])

    case File.read(path) do
      {:ok, bytes} ->
        Jason.decode!(bytes)

      {:error, reason} ->
        raise "cannot read #{path}: #{:file.format_error(reason)} — the release is " <>
                "incomplete, so its source identity cannot be attested"
    end
  end

  # --- reads -----------------------------------------------------------------

  defp current_snapshot do
    # AUTHORIZATION: transaction visibility metadata, not actor-owned data.
    %{rows: [[snapshot]]} = Repo.query!("SELECT pg_current_snapshot()::text", [])
    snapshot
  end

  # --- signing ---------------------------------------------------------------

  @doc false
  def canonical(payload), do: Jason.encode!(payload)

  defp peer_public_key, do: identity_column("peer_public_key")

  # A missing identity means this node has never been provisioned. Fail saying
  # so, rather than letting a match error surface as an unreadable struct dump
  # — and never provision one here: minting a signing key as a side effect of a
  # read is exactly the kind of silent authority change this system refuses.
  defp identity_column(column) do
    # AUTHORIZATION: this peer's own singleton signing identity, not actor-owned
    # task data. The private half is used to sign and never returned to a caller.
    case Repo.query!("SELECT #{column} FROM spruce_goose_identity WHERE id IS TRUE", []) do
      %{rows: [[value]]} when is_binary(value) ->
        value

      %{rows: []} ->
        raise "no peer identity in spruce_goose_identity: this node has not been provisioned, " <>
                "so it cannot sign a review snapshot"
    end
  end

  defp sign(bytes) do
    :crypto.sign(:eddsa, :none, bytes, [identity_column("peer_private_key"), :ed25519])
  end
end
