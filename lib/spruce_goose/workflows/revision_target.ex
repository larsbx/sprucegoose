defmodule SpruceGoose.Workflows.RevisionTarget do
  use Ash.Type.Enum, values: [:roadmap, :workflow, :task, :board, :column, :filter]
end
