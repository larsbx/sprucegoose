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
      # `deploying → cancelled` exists only to withdraw a deploy operation that
      # the executor has not started; the facade and replay both require that.
      deploying: [:verifying, :failed, :rolling_back, :cancelled],
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

  # States a rollback may be requested from. `deploying` is deliberately absent:
  # a deployment is deploying exactly while its deploy operation is open, and
  # one open operation per deployment is an invariant, not a race to win.
  @rollback_sources [:ready, :failed, :verifying]
  # Entered and left within one transaction; never a resting state.
  @transient_states [:building]
  @environments [:preview, :staging, :production]

  def environments, do: @environments
  def rollback_sources, do: @rollback_sources
  def transient?(state), do: state in @transient_states

  @doc """
  Does the lifecycle admit this kind of request in `state`?

  One relation shared by the facade's preconditions and by replay, so the
  ledger refuses any history the facade could not have written.
  """
  def admits?(state, _environment, :health), do: state == :verifying
  def admits?(state, _environment, :activate), do: state == :ready
  def admits?(state, _environment, :cancel), do: allowed?(state, :cancelled)
  def admits?(state, _environment, :rollback), do: state in @rollback_sources
  def admits?(state, _environment, {:operation, :execute_deploy}), do: state == :staged

  def admits?(state, _environment, {:operation, :execute_rollback}),
    do: state in @rollback_sources

  def admits?(state, :preview, {:operation, :execute_reclaim}), do: terminal?(state)
  def admits?(_state, _environment, _event), do: false

  @doc "Environments whose deployments require fresh routing evidence before execution."
  def requires_routing?(environment), do: environment == :production
end
