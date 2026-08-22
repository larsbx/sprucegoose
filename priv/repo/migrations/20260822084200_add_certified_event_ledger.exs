defmodule SpruceGoose.Repo.Migrations.AddCertifiedEventLedger do
  use Ecto.Migration

  def up do
    create table(:certified_events, primary_key: false) do
      add(:sequence, :bigserial, primary_key: true)
      add(:stream, :text, null: false)
      add(:stream_position, :bigint, null: false)
      add(:event_type, :text, null: false)
      add(:idempotency_key, :text, null: false)
      add(:payload, :map, null: false)
      add(:roots, :map, null: false)
      add(:canonical_bytes, :binary, null: false)
      add(:identity_algorithm, :text, null: false)
      add(:identity_digest, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(unique_index(:certified_events, [:stream, :stream_position]))
    create(unique_index(:certified_events, [:stream, :idempotency_key]))
    create(unique_index(:certified_events, [:identity_algorithm, :identity_digest]))

    create(
      constraint(:certified_events, :certified_event_identity_shape,
        check:
          "identity_algorithm = 'sha256' AND identity_digest ~ '^[0-9a-f]{64}$' AND " <>
            "octet_length(canonical_bytes) > 0 AND " <>
            "encode(sha256(canonical_bytes), 'hex') = identity_digest"
      )
    )

    execute("""
    ALTER TABLE certified_events
    ADD CONSTRAINT certified_event_required_roots CHECK (
      jsonb_typeof(roots) = 'object' AND
      roots ?& ARRAY[
        'ontology', 'schema', 'norm', 'policy', 'grant_epoch',
        'agent_charter', 'interpreter', 'evidence_policy'
      ] AND
      (roots->>'ontology') ~ '^sha256:[0-9a-f]{64}$' AND
      (roots->>'schema') ~ '^sha256:[0-9a-f]{64}$' AND
      (roots->>'norm') ~ '^sha256:[0-9a-f]{64}$' AND
      (roots->>'policy') ~ '^sha256:[0-9a-f]{64}$' AND
      (roots->>'grant_epoch') ~ '^sha256:[0-9a-f]{64}$' AND
      (roots->>'agent_charter') ~ '^sha256:[0-9a-f]{64}$' AND
      (roots->>'interpreter') ~ '^sha256:[0-9a-f]{64}$' AND
      (roots->>'evidence_policy') ~ '^sha256:[0-9a-f]{64}$'
    )
    """)

    execute("""
    CREATE FUNCTION refuse_certified_event_mutation() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'certified events are immutable';
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER certified_events_immutable
    BEFORE UPDATE OR DELETE ON certified_events
    FOR EACH ROW EXECUTE FUNCTION refuse_certified_event_mutation()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS certified_events_immutable ON certified_events")
    execute("DROP FUNCTION IF EXISTS refuse_certified_event_mutation()")
    drop(table(:certified_events))
  end
end
