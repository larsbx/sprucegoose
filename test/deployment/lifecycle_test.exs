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

  test "routing evidence is required exactly for production" do
    assert Lifecycle.requires_routing?(:production)
    refute Lifecycle.requires_routing?(:staging)
    refute Lifecycle.requires_routing?(:preview)
  end
end
