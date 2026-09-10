defmodule SpruceGoose.Deployment.Contract do
  @moduledoc "Versioned release identity and deployment lifecycle contract."

  @version 1
  @states [
    :queued,
    :building,
    :staged,
    :deploying,
    :verifying,
    :ready,
    :failed,
    :rolling_back,
    :rolled_back,
    :cancelled
  ]
  @transitions %{
    queued: [:building, :cancelled],
    building: [:staged, :failed, :cancelled],
    staged: [:deploying, :cancelled],
    deploying: [:verifying, :failed, :rolling_back],
    verifying: [:ready, :failed, :rolling_back],
    ready: [:rolling_back],
    failed: [:rolling_back],
    rolling_back: [:rolled_back, :failed],
    rolled_back: [],
    cancelled: []
  }
  @terminal_states [:ready, :failed, :rolled_back, :cancelled]

  def version, do: @version
  def states, do: @states
  def transitions, do: @transitions
  def terminal_states, do: @terminal_states
end
