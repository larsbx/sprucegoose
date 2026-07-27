defmodule Orchestrator.Repo.Migrations.EnforceDependencyGraphIntegrity do
  use Ecto.Migration

  def up do
    alter table(:task_dependencies) do
      add(:workflow_id, :uuid)
    end

    execute("""
    UPDATE task_dependencies AS dependency
    SET workflow_id = predecessor.workflow_id
    FROM workflow_tasks AS predecessor, workflow_tasks AS successor
    WHERE predecessor.id = dependency.predecessor_id
      AND successor.id = dependency.successor_id
      AND predecessor.workflow_id = successor.workflow_id
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM task_dependencies WHERE workflow_id IS NULL) THEN
        RAISE EXCEPTION 'existing dependency edges cross workflow boundaries';
      END IF;
    END
    $$;
    """)

    alter table(:task_dependencies) do
      modify(
        :workflow_id,
        references(:workflows,
          column: :id,
          name: "task_dependencies_workflow_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
    end

    execute("""
    CREATE OR REPLACE FUNCTION enforce_task_dependency_integrity()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = ''
    AS $$
    DECLARE
      predecessor_workflow uuid;
      successor_workflow uuid;
    BEGIN
      SELECT workflow_id INTO predecessor_workflow
      FROM public.workflow_tasks
      WHERE id = NEW.predecessor_id;

      SELECT workflow_id INTO successor_workflow
      FROM public.workflow_tasks
      WHERE id = NEW.successor_id;

      IF predecessor_workflow IS NULL OR successor_workflow IS NULL THEN
        RAISE EXCEPTION 'dependency endpoint does not exist';
      END IF;

      IF predecessor_workflow <> successor_workflow THEN
        RAISE EXCEPTION 'dependency endpoints must belong to the same workflow';
      END IF;

      NEW.workflow_id := predecessor_workflow;
      PERFORM pg_advisory_xact_lock(hashtextextended(NEW.workflow_id::text, 0));

      IF EXISTS (
        WITH RECURSIVE reachable(id) AS (
          SELECT NEW.successor_id
          UNION
          SELECT dependency.successor_id
          FROM public.task_dependencies AS dependency
          JOIN reachable ON dependency.predecessor_id = reachable.id
          WHERE dependency.workflow_id = NEW.workflow_id
        )
        SELECT 1 FROM reachable WHERE id = NEW.predecessor_id
      ) THEN
        RAISE EXCEPTION 'dependency would create a cycle';
      END IF;

      RETURN NEW;
    END
    $$;
    """)

    execute("""
    CREATE TRIGGER task_dependencies_integrity
    BEFORE INSERT OR UPDATE OF predecessor_id, successor_id
    ON task_dependencies
    FOR EACH ROW
    EXECUTE FUNCTION enforce_task_dependency_integrity()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS task_dependencies_integrity ON task_dependencies")
    execute("DROP FUNCTION IF EXISTS enforce_task_dependency_integrity()")

    drop(constraint(:task_dependencies, "task_dependencies_workflow_id_fkey"))

    alter table(:task_dependencies) do
      remove(:workflow_id)
    end
  end
end
