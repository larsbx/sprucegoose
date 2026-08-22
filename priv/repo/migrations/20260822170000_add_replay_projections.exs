defmodule SpruceGoose.Repo.Migrations.AddReplayProjections do
  use Ecto.Migration

  def up do
    create table(:replay_projections, primary_key: false) do
      add(:projection_id, :text, primary_key: true)
      add(:stream_position, :bigint, null: false)
      add(:state, :map, null: false)
      add(:state_digest, :text, null: false)
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    execute("""
    ALTER TABLE replay_projections ADD CONSTRAINT replay_projection_identity CHECK (
      projection_id = 'sprucegoose-authoritative-tasks-v1' AND
      state_digest ~ '^[0-9a-f]{64}$'
    )
    """)

    execute("""
    CREATE FUNCTION refuse_direct_replay_projection_write() RETURNS trigger AS $$
    BEGIN
      IF current_setting('sprucegoose.projector_write', true) IS DISTINCT FROM 'on' THEN
        RAISE EXCEPTION 'replay projections are projector-owned';
      END IF;
      RETURN COALESCE(NEW, OLD);
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER replay_projections_projector_owned
    BEFORE INSERT OR UPDATE OR DELETE ON replay_projections
    FOR EACH ROW EXECUTE FUNCTION refuse_direct_replay_projection_write()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS replay_projections_projector_owned ON replay_projections")
    execute("DROP FUNCTION IF EXISTS refuse_direct_replay_projection_write()")
    drop(table(:replay_projections))
  end
end
