defmodule SpruceGoose.Deployment.StateMachine do
  @moduledoc "Fail-closed deployment lifecycle transitions."

  alias SpruceGoose.Deployment.Contract

  def transition(from, to) do
    if to in Map.get(Contract.transitions(), from, []) do
      {:ok, to}
    else
      {:error, :invalid_transition}
    end
  end

  def terminal?(state), do: state in Contract.terminal_states()
end
