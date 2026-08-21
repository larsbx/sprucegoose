defmodule SpruceGoose.Workflows do
  use Ash.Domain, extensions: [AshAi]

  # `:when_requested` rather than Ash's `:by_default`. Every write reaches these
  # resources through `SpruceGoose.Authz`, which always passes `authorize?: true`
  # and an actor; `test/authz_lint_test.exs` fails the build if a CLI module
  # calls Ash directly. That keeps the 142 legitimate system-level `Ash.*` calls
  # in the suite working without rewriting each one to opt out.
  authorization do
    authorize(:when_requested)
  end

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
    resource(SpruceGoose.Workflows.Revision)
    resource(SpruceGoose.Workflows.BlueprintRevision)
  end
end
