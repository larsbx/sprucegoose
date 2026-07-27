defmodule SpruceGoose.Workflows.TaskKind do
  use Ash.Type.Enum, values: [:oban, :taskflow, :openclaw]
end
