defmodule SpruceGoose.Workflows.Lifecycle do
  @moduledoc false

  @transitions %{
    inbox: [:proposed, :cancelled],
    proposed: [:queued, :cancelled],
    queued: [:ready, :blocked, :cancelled],
    ready: [:in_progress, :blocked, :cancelled],
    in_progress: [:waiting, :blocked, :completed, :failed, :cancelled],
    waiting: [:ready, :in_progress, :blocked, :cancelled],
    blocked: [:ready, :cancelled],
    failed: [:queued, :cancelled],
    completed: [],
    cancelled: []
  }

  def allowed?(from, to), do: to in Map.get(@transitions, from, [])
  def allowed_from(state), do: Map.get(@transitions, state, [])
end
