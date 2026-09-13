defmodule SpruceGoose.Deployment.Lifecycle do
  @moduledoc """
  Versioned, fail-closed deployment lifecycle contract.

  State names and the transition relation are carried over unchanged from the
  native deployment control plane so that historical evidence recorded under
  that contract keeps its meaning here.
  """

  use SpruceGoose.Lifecycle,
    version: 1,
    initial: :queued,
    transitions: [
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
    ],
    # A terminal state is one in which the rollout has *finished*. `ready` and
    # `failed` are terminal even though rollback may still leave them: rollback
    # is a new operation on a finished deployment, not a continuation of it.
    terminal: [:ready, :failed, :rolled_back, :cancelled]

  @environments [:preview, :staging, :production]

  def environments, do: @environments

  @doc "Environments whose deployments require fresh routing evidence before execution."
  def requires_routing?(environment), do: environment == :production
end
