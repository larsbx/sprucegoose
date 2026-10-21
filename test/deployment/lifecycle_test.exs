defmodule SpruceGoose.Deployment.LifecycleTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Deployment.Lifecycle

  test "the contract is versioned and every state is either terminal or has successors" do
    assert Lifecycle.version() == 1

    for state <- Lifecycle.states(), Lifecycle.transitions()[state] == [] do
      assert Lifecycle.terminal?(state)
    end

    # Rollback leaves a finished deployment; it does not make ready non-terminal.
    assert Lifecycle.terminal?(:ready) and Lifecycle.terminal?(:failed)

    assert Enum.sort(Lifecycle.terminal_states()) == [:cancelled, :failed, :ready, :rolled_back]
  end

  test "only declared transitions are accepted" do
    assert {:ok, :building} = Lifecycle.transition(:queued, :building)
    assert {:ok, :rolling_back} = Lifecycle.transition(:ready, :rolling_back)
    assert {:ok, :cancelled} = Lifecycle.transition(:deploying, :cancelled)
    assert {:error, :invalid_transition} = Lifecycle.transition(:queued, :ready)
    assert {:error, :invalid_transition} = Lifecycle.transition(:ready, :deploying)
    assert {:error, :invalid_transition} = Lifecycle.transition(:cancelled, :queued)
    assert {:error, :invalid_transition} = Lifecycle.transition(:unknown, :queued)
  end

  test "persisted names parse back into the closed set only" do
    assert {:ok, :verifying} = Lifecycle.parse("verifying")
    assert {:ok, :verifying} = Lifecycle.parse(:verifying)
    assert {:error, :unknown_state} = Lifecycle.parse("sudo")
    assert {:error, :unknown_state} = Lifecycle.parse(:sudo)
  end

  test "one admission relation serves the facade and replay" do
    assert Lifecycle.admits?(:verifying, :staging, :health)
    refute Lifecycle.admits?(:ready, :staging, :health)
    assert Lifecycle.admits?(:staged, :staging, :cancel)
    # Withdrawal: admitted by the contract, and further guarded by the open operation's phase.
    assert Lifecycle.admits?(:deploying, :staging, :cancel)
    refute Lifecycle.admits?(:verifying, :staging, :cancel)
    assert Lifecycle.admits?(:staged, :staging, {:operation, :execute_deploy})
    refute Lifecycle.admits?(:deploying, :staging, {:operation, :execute_deploy})

    for state <- Lifecycle.rollback_sources() do
      assert Lifecycle.admits?(state, :staging, :rollback)
      assert Lifecycle.admits?(state, :staging, {:operation, :execute_rollback})
    end

    # A deployment is deploying exactly while its deploy operation is open.
    refute :deploying in Lifecycle.rollback_sources()
    refute Lifecycle.admits?(:deploying, :staging, :rollback)

    assert Lifecycle.admits?(:cancelled, :preview, {:operation, :execute_reclaim})
    refute Lifecycle.admits?(:cancelled, :staging, {:operation, :execute_reclaim})
    refute Lifecycle.admits?(:staged, :preview, {:operation, :execute_reclaim})
    refute Lifecycle.admits?(:ready, :staging, {:operation, :sudo})

    assert Lifecycle.transient?(:building)
    refute Lifecycle.transient?(:staged)
  end

  test "routing evidence is required exactly for production" do
    assert Lifecycle.requires_routing?(:production)
    refute Lifecycle.requires_routing?(:staging)
    refute Lifecycle.requires_routing?(:preview)
  end
end
