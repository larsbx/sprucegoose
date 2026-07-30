defmodule SpruceGoose.Repo.Migrations.PreserveIdentityPrivateKey do
  @moduledoc """
  Upgrades databases that applied the identity seam before private-key custody.

  A public-only peer cannot be repaired by inventing a new private key. The
  migration fails closed if such a row exists so the operator must restore the
  seed or explicitly reset an unused identity before retrying.
  """

  use Ecto.Migration

  def up do
    alter table(:spruce_goose_identity) do
      add_if_not_exists(:peer_private_key, :binary)
    end

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM spruce_goose_identity WHERE peer_private_key IS NULL) THEN
        RAISE EXCEPTION
          'public-only SpruceGoose identity cannot be upgraded: restore or reset the unused peer identity';
      END IF;
    END;
    $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'spruce_goose_identity_private_key_length'
      ) THEN
        ALTER TABLE spruce_goose_identity
          ADD CONSTRAINT spruce_goose_identity_private_key_length
          CHECK (octet_length(peer_private_key) = 32);
      END IF;
    END;
    $$;
    """)

    execute(
      "ALTER TABLE spruce_goose_identity ALTER COLUMN peer_private_key SET NOT NULL",
      "ALTER TABLE spruce_goose_identity ALTER COLUMN peer_private_key DROP NOT NULL"
    )

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
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION spruce_goose_identity_immutable() RETURNS trigger AS $$
    BEGIN
      IF NEW.peer_public_key <> OLD.peer_public_key THEN
        RAISE EXCEPTION 'peer_public_key is immutable';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    drop_if_exists(constraint(:spruce_goose_identity, :spruce_goose_identity_private_key_length))

    alter table(:spruce_goose_identity) do
      remove_if_exists(:peer_private_key, :binary)
    end
  end
end
