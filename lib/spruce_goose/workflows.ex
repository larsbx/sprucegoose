defmodule SpruceGoose.Workflows do
  use Ash.Domain

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
    resource(SpruceGoose.Workflows.InboxItem)
  end
end
