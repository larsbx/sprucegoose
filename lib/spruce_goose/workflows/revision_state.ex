defmodule SpruceGoose.Workflows.RevisionState do
  use Ash.Type.Enum, values: [:pending, :applied, :withdrawn]
end
