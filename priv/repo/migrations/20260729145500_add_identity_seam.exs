defmodule SpruceGoose.Repo.Migrations.AddIdentitySeam do
  @moduledoc """
  Durable peer identity and origin sequence for the identifier model
  (docs/identifier-model.md).

  Infrastructure state, not domain state, so it follows the
  spruce_goose_authority precedent: a raw single-row table rather than an Ash
  resource. That keeps it out of resource snapshots and out of the domain
  resource list.

  origin_seq is a Postgres SEQUENCE rather than a counter column. nextval()
  never returns the same value twice; after a crash it may SKIP values, which
  is the correct trade. Gaps are harmless (IDs stay distinct); reuse is fatal
  (two distinct events mint the same ID). Sequences are also non-transactional,
  so a rolled-back transaction does not return its value to the pool.
  """

  use Ecto.Migration

  def up do
    create table(:spruce_goose_identity, primary_key: false) do
      add(:id, :boolean, primary_key: true, default: true, null: false)
      add(:peer_public_key, :binary, null: false)
      add(:peer_private_key, :binary, null: false)
      add(:key_algorithm, :text, null: false, default: "ed25519")

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    # Single row only: id must be TRUE, and it is the primary key.
    create(
      constraint(:spruce_goose_identity, :spruce_goose_identity_singleton, check: "id IS TRUE")
    )

    # Ed25519 public keys are exactly 32 bytes.
    create(
      constraint(:spruce_goose_identity, :spruce_goose_identity_key_length,
        check: "octet_length(peer_public_key) = 32"
      )
    )

    create(
      constraint(:spruce_goose_identity, :spruce_goose_identity_private_key_length,
        check: "octet_length(peer_private_key) = 32"
      )
    )

    create(
      constraint(:spruce_goose_identity, :spruce_goose_identity_algorithm,
        check: "key_algorithm = 'ed25519'"
      )
    )

    # The peer key is the peer's identity. Rotating it silently would re-key
    # every future derivation while leaving minted IDs claiming the old key.
    execute("""
    CREATE OR REPLACE FUNCTION spruce_goose_identity_immutable() RETURNS trigger AS $$
    BEGIN
      IF NEW.peer_public_key <> OLD.peer_public_key
         OR NEW.peer_private_key <> OLD.peer_private_key THEN
        RAISE EXCEPTION 'peer keypair is immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER spruce_goose_identity_immutable
    BEFORE UPDATE ON spruce_goose_identity
    FOR EACH ROW EXECUTE FUNCTION spruce_goose_identity_immutable();
    """)

    execute("CREATE SEQUENCE spruce_goose_origin_seq AS bigint START WITH 1 INCREMENT BY 1")
  end

  def down do
    execute("DROP SEQUENCE IF EXISTS spruce_goose_origin_seq")
    execute("DROP TRIGGER IF EXISTS spruce_goose_identity_immutable ON spruce_goose_identity")
    execute("DROP FUNCTION IF EXISTS spruce_goose_identity_immutable()")
    drop(table(:spruce_goose_identity))
  end
end
