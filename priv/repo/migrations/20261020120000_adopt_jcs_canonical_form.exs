defmodule SpruceGoose.Repo.Migrations.AdoptJcsCanonicalForm do
  @moduledoc """
  Record which canonical form each certified event and projection digest was
  derived in, and add the immutable re-rooting record that maps every legacy
  (etf-v1) identity to its jcs-v1 identity. Existing rows are not touched:
  the column default labels them as legacy without an UPDATE, which their
  immutability trigger would refuse.
  """

  use Ecto.Migration

  def up do
    alter table(:certified_events) do
      add(:canonical_form, :text, null: false, default: "etf-v1")
    end

    alter table(:replay_projections) do
      add(:canonical_form, :text, null: false, default: "etf-v1")
    end

    execute("""
    ALTER TABLE certified_events
      ADD CONSTRAINT certified_event_canonical_form CHECK (canonical_form IN ('etf-v1', 'jcs-v1'))
    """)

    execute("""
    ALTER TABLE replay_projections
      ADD CONSTRAINT replay_projection_canonical_form CHECK (canonical_form IN ('etf-v1', 'jcs-v1'))
    """)

    create table(:certified_event_rekeys, primary_key: false) do
      add(:sequence, :bigint, primary_key: true)
      add(:identity_algorithm, :text, null: false, default: "sha256")
      add(:identity_digest, :text, null: false)
      add(:jcs_digest, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(unique_index(:certified_event_rekeys, [:identity_digest]))
    create(unique_index(:certified_event_rekeys, [:jcs_digest]))

    execute("""
    ALTER TABLE certified_event_rekeys
      ADD CONSTRAINT certified_event_rekey_shape CHECK (
        identity_digest ~ '^[0-9a-f]{64}$' AND jcs_digest ~ '^[0-9a-f]{64}$'
      ),
      ADD CONSTRAINT certified_event_rekey_event_fk
        FOREIGN KEY (identity_algorithm, identity_digest)
        REFERENCES certified_events(identity_algorithm, identity_digest)
    """)

    execute("""
    CREATE TRIGGER certified_event_rekeys_immutable
    BEFORE UPDATE OR DELETE ON certified_event_rekeys
    FOR EACH ROW EXECUTE FUNCTION refuse_certified_event_mutation()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS certified_event_rekeys_immutable ON certified_event_rekeys")
    drop(table(:certified_event_rekeys))
    execute("ALTER TABLE replay_projections DROP CONSTRAINT replay_projection_canonical_form")
    execute("ALTER TABLE certified_events DROP CONSTRAINT certified_event_canonical_form")

    alter table(:replay_projections) do
      remove(:canonical_form)
    end

    alter table(:certified_events) do
      remove(:canonical_form)
    end
  end
end
