defmodule SpruceGoose.Workflows.TaskState do
  @moduledoc "The persisted task state enum: exactly the task lifecycle's state set."

  use Ash.Type.Enum, values: SpruceGoose.Workflows.Lifecycle.states()
end
