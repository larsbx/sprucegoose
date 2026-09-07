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
  """

  @behaviour SpruceGoose.Identity

  alias SpruceGoose.Repo

  @impl true
  def peer_id do
    # AUTHORIZATION: internal singleton node identity, not actor-owned task data.
    case Repo.query!("SELECT peer_public_key FROM spruce_goose_identity WHERE id IS TRUE", []) do
      %{rows: [[key]]} when is_binary(key) -> key
      %{rows: []} -> provision_peer_key()
    end
  end

  @evidence_domain "sprucegoose-authority-evidence-snapshot-v1\0"
  @ed25519_key_bytes 32
  @ed25519_sig_bytes 64

  @doc """
  Read the existing peer identity without ever provisioning one.

  `peer_id/0` deliberately self-heals by minting a key when the singleton row
  is absent. That is correct for bootstrap and wrong for evidence: a
  capability check must be able to report "no identity" without creating one,
  and inside a `READ ONLY` transaction the provisioning INSERT would fail with
  SQLSTATE 25006 and poison the transaction instead of returning a typed
  refusal.

  Selects only the public half and the algorithm. The private key is never
  read here.
  """
  @spec fetch_existing_identity() ::
          {:ok, %{public_key: binary(), algorithm: String.t()}}
          | {:error, :identity_unavailable}
          | {:error, :identity_invalid}
          | {:error, :unsupported_algorithm}
  def fetch_existing_identity do
    # AUTHORIZATION: reads the singleton node identity's public half only.
    case Repo.query!(
           "SELECT peer_public_key, key_algorithm FROM spruce_goose_identity WHERE id IS TRUE",
           []
         ) do
      %{rows: []} ->
        {:error, :identity_unavailable}

      %{rows: [[key, algorithm]]}
      when is_binary(key) and byte_size(key) == @ed25519_key_bytes and is_binary(algorithm) ->
        if String.downcase(algorithm) == "ed25519" do
          {:ok, %{public_key: key, algorithm: String.downcase(algorithm)}}
        else
          {:error, :unsupported_algorithm}
        end

      %{rows: [[_, _]]} ->
        {:error, :identity_invalid}

      _ ->
        {:error, :identity_invalid}
    end
  end

  @doc """
  The exact message signed for authority evidence.

  Domain-separated so a signature over an evidence digest can never be
  replayed as a signature over anything else. The digest must be exactly 32
  bytes; the guard is a function clause so a wrong-sized input cannot slip
  through as a shorter framed message.
  """
  @spec authority_evidence_message(<<_::256>>) :: binary()
  def authority_evidence_message(<<digest::binary-size(32)>>),
    do: @evidence_domain <> digest

  @doc """
  Sign an authority-evidence payload digest.

  Deliberately not a general `sign/1` oracle: a generic signer over the peer
  key would let any caller obtain an authority signature over arbitrary bytes.
  This accepts only a 32-byte digest and only ever signs the fixed framing.

  `expected_public_key` is the key recorded inside the snapshot transaction.
  If the stored identity no longer matches it, the identity changed between
  snapshot and signing and the result is `:identity_changed` — no signature is
  produced. Private key bytes never leave this function.
  """
  @spec sign_authority_evidence_digest(binary(), binary()) ::
          {:ok, %{signature: binary(), public_key: binary(), algorithm: String.t()}}
          | {:error,
             :invalid_digest
             | :identity_unavailable
             | :identity_changed
             | :identity_invalid
             | :unsupported_algorithm
             | :signing_failed}
  def sign_authority_evidence_digest(digest, _expected_public_key)
      when not (is_binary(digest) and byte_size(digest) == 32),
      do: {:error, :invalid_digest}

  def sign_authority_evidence_digest(digest, expected_public_key)
      when is_binary(digest) and byte_size(digest) == 32 do
    # AUTHORIZATION: reads the singleton node identity to sign fixed evidence framing.
    case Repo.query!(
           "SELECT peer_public_key, peer_private_key, key_algorithm FROM spruce_goose_identity WHERE id IS TRUE",
           []
         ) do
      %{rows: []} ->
        {:error, :identity_unavailable}

      %{rows: [[public, private, algorithm]]} ->
        do_sign(digest, expected_public_key, public, private, algorithm)

      _ ->
        {:error, :identity_invalid}
    end
  end

  defp do_sign(digest, expected_public_key, public, private, algorithm) do
    cond do
      not (is_binary(public) and byte_size(public) == @ed25519_key_bytes) ->
        {:error, :identity_invalid}

      not (is_binary(private) and byte_size(private) == @ed25519_key_bytes) ->
        {:error, :identity_invalid}

      not (is_binary(algorithm) and String.downcase(algorithm) == "ed25519") ->
        {:error, :unsupported_algorithm}

      not (is_binary(expected_public_key) and
             :crypto.hash_equals(public, expected_public_key)) ->
        {:error, :identity_changed}

      true ->
        message = authority_evidence_message(digest)

        try do
          signature = :crypto.sign(:eddsa, :none, message, [private, :ed25519])

          if byte_size(signature) == @ed25519_sig_bytes do
            {:ok,
             %{signature: signature, public_key: public, algorithm: String.downcase(algorithm)}}
          else
            {:error, :signing_failed}
          end
        rescue
          _ -> {:error, :signing_failed}
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
