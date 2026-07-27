defmodule Orchestrator.Workflows do
  use Ash.Domain

  resources do
    resource(Orchestrator.Workflows.Project)
    resource(Orchestrator.Workflows.Roadmap)
    resource(Orchestrator.Workflows.Workflow)
    resource(Orchestrator.Workflows.Task)
    resource(Orchestrator.Workflows.Dependency)
    resource(Orchestrator.Workflows.Todo)
    resource(Orchestrator.Workflows.InboxItem)
  end
end
