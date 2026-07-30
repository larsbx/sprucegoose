defmodule SpruceGoose.Workflows do
  use Ash.Domain, extensions: [AshAi]

  # Read-only MCP tool surface.
  #
  # SpruceGoose is the authoritative task substrate, so the MCP server
  # deliberately exposes only `:read` actions. Lifecycle transitions
  # (propose/queue/ready/start/done/cancel) stay behind the governed CLI
  # where SOP-gate enforcement and evidence linking live. Widening this
  # surface to mutating actions is a separate security decision.
  tools do
    tool(:list_tasks, SpruceGoose.Workflows.Task, :read)
    tool(:list_projects, SpruceGoose.Workflows.Project, :read)
    tool(:list_roadmaps, SpruceGoose.Workflows.Roadmap, :read)
    tool(:list_workflows, SpruceGoose.Workflows.Workflow, :read)
    tool(:list_todos, SpruceGoose.Workflows.Todo, :read)
  end

  resources do
    resource(SpruceGoose.Workflows.Project)
    resource(SpruceGoose.Workflows.Roadmap)
    resource(SpruceGoose.Workflows.Workflow)
    resource(SpruceGoose.Workflows.Board)
    resource(SpruceGoose.Workflows.BoardColumn)
    resource(SpruceGoose.Workflows.SavedFilter)
    resource(SpruceGoose.Workflows.Task)
    resource(SpruceGoose.Workflows.Dependency)
    resource(SpruceGoose.Workflows.Todo)
    resource(SpruceGoose.Workflows.TodoDependency)
    resource(SpruceGoose.Workflows.InboxItem)
  end
end
