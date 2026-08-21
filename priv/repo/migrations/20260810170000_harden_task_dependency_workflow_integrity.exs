defmodule SpruceGoose.Repo.Migrations.HardenTaskDependencyWorkflowIntegrity do
  use Ecto.Migration

  def up do
    execute("""
    CREATE FUNCTION reject_task_dependency_workflow_change()
    RETURNS trigger
    LANGUAGE plpgsql
    SET search_path = ''
    AS $$
    BEGIN
      IF NEW.workflow_id IS DISTINCT FROM OLD.workflow_id THEN
        RAISE EXCEPTION 'dependency workflow_id must match its endpoints';
      END IF;

      RETURN NEW;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER task_dependencies_workflow_integrity
    BEFORE UPDATE OF workflow_id
    ON task_dependencies
    FOR EACH ROW
    EXECUTE FUNCTION reject_task_dependency_workflow_change()
    """)
  end

  def down do
    execute("DROP TRIGGER IF EXISTS task_dependencies_workflow_integrity ON task_dependencies")
    execute("DROP FUNCTION IF EXISTS reject_task_dependency_workflow_change()")
  end
end
