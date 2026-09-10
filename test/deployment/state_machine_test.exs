defmodule SpruceGoose.Deployment.StateMachineTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Deployment.{Contract, StateMachine}

  test "the versioned contract covers every state exactly once" do
    assert Contract.version() == 1

    assert Contract.states() |> MapSet.new() ==
             Contract.transitions() |> Map.keys() |> MapSet.new()
  end

  test "allows only declared transitions" do
    for from <- Contract.states(), to <- Contract.states() do
      if to in Map.fetch!(Contract.transitions(), from) do
        assert {:ok, ^to} = StateMachine.transition(from, to)
      else
        assert {:error, :invalid_transition} = StateMachine.transition(from, to)
      end
    end
  end

  test "unknown states and terminal states fail closed" do
    assert {:error, :invalid_transition} = StateMachine.transition(:unknown, :ready)

    for terminal <- [:ready, :failed, :rolled_back, :cancelled] do
      assert StateMachine.terminal?(terminal)
    end

    refute StateMachine.terminal?(:verifying)
    refute StateMachine.terminal?(:unknown)
  end
end
