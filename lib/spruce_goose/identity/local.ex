defmodule SpruceGoose.Identity.Local do
  @moduledoc """
  Local adapter for `SpruceGoose.Identity` (docs/identifier-model.md).

  Deliberately the only adapter today, and deliberately replaceable. When
  `coop_substrate` is assimilated its canonical log supplies `global_seq` /
  `stream_seq` and Ed25519 signer sets, and this module is deleted rather
  than migrated: IDs already minted stay valid because a dot does not change
  meaning when the counter's storage moves.

  ## Durability

  `origin_seq` is a Postgres SEQUENCE. `nextval()` never returns a value twice,
  including across restarts and crashes. After an unclean shutdown it may SKIP
  values, which is the correct trade: gaps keep IDs distinct, reuse would mint
  colliding IDs for distinct events. Sequences are also non-transactional, so a
  rolled-back transaction does not return its value to the pool.

  ## Key handling

  The peer keypair lives in `spruce_goose_identity`, a raw single-row table
  guarded by a DB trigger that rejects changes to either key half. Retaining the
  private seed is mandatory so the peer can later prove ownership.

  That seed is stored in plaintext, in the application's own database, and the
  trigger protects it against *modification* rather than disclosure: any read of
  that table, any backup, any `pg_dump` carries it. `docs/current-state.md`
  describes the right custody model for the artifact-signer key — a root-managed
  identity the application cannot read or replace — and this key has none of it.
  Closing that needs external custody, which is a deployment change rather than
  a code one; it is recorded in the 2026-09-08 audit as C-04 and is not fixed
  here. What is fixed is that the key is no longer minted as a side effect of a
  read.
  """

  @behaviour SpruceGoose.Identity

  alias SpruceGoose.Repo

  @impl true
  def peer_id do
    # AUTHORIZATION: internal singleton node identity, not actor-owned task data.
    case Repo.query!("SELECT peer_public_key FROM spruce_goose_identity WHERE id IS TRUE", []) do
      %{rows: [[key]]} when is_binary(key) ->
        key

      %{rows: []} ->
        # Minting an Ed25519 keypair is a provisioning act, not a read. Doing it
        # lazily from here meant the peer's long-term private key came into
        # existence as a side effect of whichever request happened to ask for
        # the peer id first, with no authorization and no record of the moment.
        if Application.get_env(:spruce_goose, :auto_provision_peer_key, true) do
          provision_peer_key()
        else
          raise "this store has no peer identity. Provision one explicitly with " <>
                  "SpruceGoose.Identity.Local.provision_peer_key/0"
        end
    end
  end

  @impl true
  def next_seq do
    # AUTHORIZATION: internal monotonic origin sequence, not actor-owned task data.
    %{rows: [[seq]]} = Repo.query!("SELECT nextval('spruce_goose_origin_seq')", [])
    seq
  end

  @impl true
  def origin_wall_ms, do: System.system_time(:millisecond)

  @doc """
  Provision this peer's key exactly once.

  Concurrent callers race harmlessly: the singleton primary key means one
  insert wins and the loser reads the winner's key. Never overwrites, so a
  second call cannot silently re-key the peer.
  """
  def provision_peer_key do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)

    # AUTHORIZATION: internal one-time node identity provisioning guarded by DB constraints.
    Repo.query!(
      """
      INSERT INTO spruce_goose_identity
        (id, peer_public_key, peer_private_key, key_algorithm)
      VALUES (TRUE, $1, $2, 'ed25519')
      ON CONFLICT (id) DO NOTHING
      """,
      [public_key, private_key]
    )

    # AUTHORIZATION: reads the singleton provisioned immediately above.
    %{rows: [[key]]} =
      Repo.query!("SELECT peer_public_key FROM spruce_goose_identity WHERE id IS TRUE", [])

    key
  end
end
