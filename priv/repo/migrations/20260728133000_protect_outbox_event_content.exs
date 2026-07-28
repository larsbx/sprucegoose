defmodule SpruceGoose.Repo.Migrations.ProtectOutboxEventContent do
  use Ecto.Migration

  def up do
    execute("""
    CREATE FUNCTION spruce_goose_protect_outbox_event_content() RETURNS trigger AS $$
    BEGIN
      IF NEW.event_key IS DISTINCT FROM OLD.event_key
         OR NEW.aggregate_type IS DISTINCT FROM OLD.aggregate_type
         OR NEW.aggregate_id IS DISTINCT FROM OLD.aggregate_id
         OR NEW.event_type IS DISTINCT FROM OLD.event_type
         OR NEW.payload IS DISTINCT FROM OLD.payload
         OR NEW.inserted_at IS DISTINCT FROM OLD.inserted_at THEN
        RAISE EXCEPTION 'outbox event content is immutable';
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER outbox_events_protect_content
    BEFORE UPDATE ON outbox_events
    FOR EACH ROW EXECUTE FUNCTION spruce_goose_protect_outbox_event_content();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS outbox_events_protect_content ON outbox_events")
    execute("DROP FUNCTION IF EXISTS spruce_goose_protect_outbox_event_content()")
  end
end
