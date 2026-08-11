defmodule SpruceGoose.Repo.Migrations.AddTaskDependencyPropertyGraph do
  use Ecto.Migration

  def up do
    execute("""
    CREATE PROPERTY GRAPH sprucegoose_task_dependency_graph
      VERTEX TABLES (
        workflow_tasks
          KEY (id)
          LABEL task
          PROPERTIES (id, task_id, title, state, workflow_id)
      )
      EDGE TABLES (
        task_dependencies
          KEY (id)
          SOURCE KEY (predecessor_id) REFERENCES workflow_tasks (id)
          DESTINATION KEY (successor_id) REFERENCES workflow_tasks (id)
          LABEL dependency
          PROPERTIES (workflow_id, source)
      )
    """)
  end

  def down do
    execute("DROP PROPERTY GRAPH sprucegoose_task_dependency_graph")
  end
end
