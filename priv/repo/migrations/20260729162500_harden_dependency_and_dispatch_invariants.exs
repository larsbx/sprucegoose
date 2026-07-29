defmodule SpruceGoose.Repo.Migrations.HardenDependencyAndDispatchInvariants do
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE task_todo_dependencies
    ADD CONSTRAINT task_todo_dependencies_task_id_fkey
    FOREIGN KEY (task_id) REFERENCES workflow_tasks(id)
    """)

    execute("""
    CREATE FUNCTION enforce_todo_dependency_integrity()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = ''
    AS $$
    DECLARE
      predecessor_task uuid;
      successor_task uuid;
    BEGIN
      SELECT task_id INTO predecessor_task FROM public.task_todos WHERE id = NEW.predecessor_id;
      SELECT task_id INTO successor_task FROM public.task_todos WHERE id = NEW.successor_id;

      IF predecessor_task IS NULL OR successor_task IS NULL THEN
        RAISE EXCEPTION 'TODO dependency endpoint does not exist';
      END IF;

      IF predecessor_task <> successor_task THEN
        RAISE EXCEPTION 'TODO dependency endpoints must belong to the same task';
      END IF;

      NEW.task_id := predecessor_task;
      PERFORM pg_advisory_xact_lock(hashtextextended(NEW.task_id::text, 0));

      IF EXISTS (
        WITH RECURSIVE reachable(id) AS (
          SELECT NEW.successor_id
          UNION
          SELECT dependency.successor_id
          FROM public.task_todo_dependencies AS dependency
          JOIN reachable ON dependency.predecessor_id = reachable.id
          WHERE dependency.task_id = NEW.task_id
        )
        SELECT 1 FROM reachable WHERE id = NEW.predecessor_id
      ) THEN
        RAISE EXCEPTION 'TODO dependency would create a cycle';
      END IF;

      RETURN NEW;
    END
    $$;
    """)

    execute("""
    CREATE TRIGGER task_todo_dependencies_integrity
    BEFORE INSERT OR UPDATE OF task_id, predecessor_id, successor_id
    ON task_todo_dependencies
    FOR EACH ROW EXECUTE FUNCTION enforce_todo_dependency_integrity()
    """)

    execute("""
    CREATE FUNCTION enforce_task_start_predecessors()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = ''
    AS $$
    BEGIN
      IF NEW.state = 'in_progress' AND OLD.state IS DISTINCT FROM NEW.state THEN
        PERFORM pg_advisory_xact_lock(hashtextextended(NEW.workflow_id::text, 0));

        IF EXISTS (
          SELECT 1
          FROM public.task_dependencies AS dependency
          JOIN public.workflow_tasks AS predecessor ON predecessor.id = dependency.predecessor_id
          WHERE dependency.successor_id = NEW.id
            AND predecessor.state <> 'completed'
        ) THEN
          RAISE EXCEPTION 'task has incomplete predecessors' USING ERRCODE = '23514';
        END IF;
      END IF;

      RETURN NEW;
    END
    $$;
    """)

    execute("""
    CREATE TRIGGER workflow_tasks_start_predecessor_guard
    BEFORE UPDATE OF state ON workflow_tasks
    FOR EACH ROW EXECUTE FUNCTION enforce_task_start_predecessors()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS workflow_tasks_start_predecessor_guard ON workflow_tasks")
    execute("DROP FUNCTION IF EXISTS enforce_task_start_predecessors()")
    execute("DROP TRIGGER IF EXISTS task_todo_dependencies_integrity ON task_todo_dependencies")
    execute("DROP FUNCTION IF EXISTS enforce_todo_dependency_integrity()")

    execute("""
    ALTER TABLE task_todo_dependencies
    DROP CONSTRAINT IF EXISTS task_todo_dependencies_task_id_fkey
    """)
  end
end
