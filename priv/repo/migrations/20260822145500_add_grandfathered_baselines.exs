defmodule SpruceGoose.Repo.Migrations.AddGrandfatheredBaselines do
  use Ecto.Migration

  def up do
    create table(:grandfathered_baselines, primary_key: false) do
      add(:baseline_id, :text, primary_key: true)
      add(:snapshot, :map, null: false)
      add(:canonical_bytes, :binary, null: false)
      add(:snapshot_digest, :text, null: false)
      add(:legacy_final_stream_position, :bigint, null: false)
      add(:acceptance_stream_position, :bigint, null: false)
      add(:migration_set_sha256, :text, null: false)
      add(:exclusions, :map, null: false)
      add(:accepted_event_digest, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(unique_index(:grandfathered_baselines, [:snapshot_digest]))
    create(unique_index(:grandfathered_baselines, [:accepted_event_digest]))

    execute("""
    ALTER TABLE grandfathered_baselines
    ADD CONSTRAINT grandfathered_baseline_identity CHECK (
      baseline_id = 'grandfathered-baseline-v1' AND
      snapshot_digest ~ '^[0-9a-f]{64}$' AND
      accepted_event_digest ~ '^[0-9a-f]{64}$' AND
      migration_set_sha256 ~ '^[0-9a-f]{64}$' AND
      encode(sha256(canonical_bytes), 'hex') = snapshot_digest AND
      acceptance_stream_position = legacy_final_stream_position + 1
    )
    """)

    execute("""
    CREATE FUNCTION refuse_grandfathered_baseline_mutation() RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'grandfathered baselines are immutable';
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER grandfathered_baselines_immutable
    BEFORE UPDATE OR DELETE ON grandfathered_baselines
    FOR EACH ROW EXECUTE FUNCTION refuse_grandfathered_baseline_mutation()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS grandfathered_baselines_immutable ON grandfathered_baselines")
    execute("DROP FUNCTION IF EXISTS refuse_grandfathered_baseline_mutation()")
    drop(table(:grandfathered_baselines))
  end
end
