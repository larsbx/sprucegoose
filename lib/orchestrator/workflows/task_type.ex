defmodule Orchestrator.Workflows.TaskType do
  use Ash.Type.Enum, values: [:task, :diagnosis]
end
