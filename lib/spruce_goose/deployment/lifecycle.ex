defmodule SpruceGoose.Deployment.Lifecycle do
  @moduledoc """
  Versioned, fail-closed deployment lifecycle contract.

  State names and the transition relation are carried over unchanged from the
  native deployment control plane so that historical evidence recorded under
  that contract keeps its meaning here.
  """

  @version 1
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
  @states Map.keys(@transitions)
  # A terminal state is one in which the rollout has *finished*. `ready` and
  # `failed` are terminal even though rollback may still leave them: rollback
  # is a new operation on a finished deployment, not a continuation of it.
  @terminal_states [:ready, :failed, :rolled_back, :cancelled]
  # States a rollback may be requested from. `deploying` is deliberately absent:
  # a deployment is deploying exactly while its deploy operation is open, and
  # one open operation per deployment is an invariant, not a race to win.
  @rollback_sources [:ready, :failed, :verifying]
  # Entered and left within one transaction; never a resting state.
  @transient_states [:building]
  @environments [:preview, :staging, :production]

  def version, do: @version
  def states, do: @states
  def transitions, do: @transitions
  def terminal_states, do: @terminal_states
  def environments, do: @environments

  def terminal?(state), do: state in @terminal_states

  @doc "The legal successor, or a refusal. Unknown states have no successors."
  def transition(from, to) do
    if to in Map.get(@transitions, from, []), do: {:ok, to}, else: {:error, :invalid_transition}
  end

  @doc "Parse a persisted state name back into the closed set."
  def parse(name) when is_binary(name) do
    Enum.find_value(
      @states,
      {:error, :unknown_state},
      &if(Atom.to_string(&1) == name, do: {:ok, &1})
    )
  end

  def parse(state) when state in @states, do: {:ok, state}
  def parse(_), do: {:error, :unknown_state}

  def rollback_sources, do: @rollback_sources
  def transient?(state), do: state in @transient_states

  @doc """
  Does the lifecycle admit this kind of request in `state`?

  One relation shared by the facade's preconditions and by replay, so the
  ledger refuses any history the facade could not have written.
  """
  def admits?(state, _environment, :health), do: state == :verifying
  def admits?(state, _environment, :cancel), do: match?({:ok, _}, transition(state, :cancelled))
  def admits?(state, _environment, :rollback), do: state in @rollback_sources
  def admits?(state, _environment, {:operation, :execute_deploy}), do: state == :staged

  def admits?(state, _environment, {:operation, :execute_rollback}),
    do: state in @rollback_sources

  def admits?(state, :preview, {:operation, :execute_reclaim}), do: terminal?(state)
  def admits?(_state, _environment, _event), do: false

  @doc "Environments whose deployments require fresh routing evidence before execution."
  def requires_routing?(environment), do: environment == :production
end
