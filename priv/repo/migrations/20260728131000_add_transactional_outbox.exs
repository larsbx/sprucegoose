defmodule SpruceGoose.Repo.Migrations.AddTransactionalOutbox do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 14)

    create table(:outbox_events, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:event_key, :text, null: false)
      add(:aggregate_type, :text, null: false)
      add(:aggregate_id, :text, null: false)
      add(:event_type, :text, null: false)
      add(:payload, :map, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:attempts, :integer, null: false, default: 0)
      add(:available_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      add(:dispatched_at, :utc_datetime_usec)
      add(:last_error, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:outbox_events, [:event_key]))
    create(index(:outbox_events, [:status, :available_at]))

    create(
      constraint(:outbox_events, :outbox_events_status_check,
        check: "status IN ('pending','dispatched','failed')"
      )
    )

    execute("""
    CREATE FUNCTION spruce_goose_capture_task_event() RETURNS trigger AS $$
    DECLARE
      kind text;
      key_value text;
    BEGIN
      kind := CASE WHEN TG_OP = 'INSERT' THEN 'task.created' ELSE 'task.changed' END;
      key_value :=
        'task:' || NEW.task_id || ':' || NEW.lock_version::text || ':' ||
        NEW.board_revision::text;

      INSERT INTO outbox_events (
        id, event_key, aggregate_type, aggregate_id, event_type, payload,
        status, attempts, available_at, inserted_at, updated_at
      ) VALUES (
        gen_random_uuid(), key_value, 'task', NEW.task_id, kind, to_jsonb(NEW),
        'pending', 0, now(), now(), now()
      ) ON CONFLICT (event_key) DO NOTHING;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER workflow_tasks_capture_outbox
    AFTER INSERT OR UPDATE ON workflow_tasks
    FOR EACH ROW EXECUTE FUNCTION spruce_goose_capture_task_event();
    """)

    execute("""
    CREATE FUNCTION spruce_goose_capture_inbox_event() RETURNS trigger AS $$
    BEGIN
      INSERT INTO outbox_events (
        id, event_key, aggregate_type, aggregate_id, event_type, payload,
        status, attempts, available_at, inserted_at, updated_at
      ) VALUES (
        gen_random_uuid(), 'inbox:' || NEW.capture_id, 'inbox', NEW.capture_id,
        'inbox.captured', to_jsonb(NEW), 'pending', 0, now(), now(), now()
      ) ON CONFLICT (event_key) DO NOTHING;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER inbox_items_capture_outbox
    AFTER INSERT ON inbox_items
    FOR EACH ROW EXECUTE FUNCTION spruce_goose_capture_inbox_event();
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS inbox_items_capture_outbox ON inbox_items")
    execute("DROP FUNCTION IF EXISTS spruce_goose_capture_inbox_event()")
    execute("DROP TRIGGER IF EXISTS workflow_tasks_capture_outbox ON workflow_tasks")
    execute("DROP FUNCTION IF EXISTS spruce_goose_capture_task_event()")
    drop(table(:outbox_events))
    Oban.Migration.down(version: 1)
  end
end
