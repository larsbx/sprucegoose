defmodule Orchestrator.Workflows.TaskState do
  use Ash.Type.Enum,
    values: [
      :inbox,
      :proposed,
      :queued,
      :ready,
      :in_progress,
      :waiting,
      :blocked,
      :completed,
      :failed,
      :cancelled
    ]
end
