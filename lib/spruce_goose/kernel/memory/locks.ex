defmodule SpruceGoose.Kernel.Memory.Locks do
  @moduledoc """
  Reference in-memory lock adapter: serialises callers within one node through
  `:global`, released when the calling process exits. For kernel proofs and
  single-node runs without a database-held lock.
  """

  @behaviour SpruceGoose.Kernel.Locks

  @impl true
  def acquire(key) do
    # Re-entrant for the holder; blocks other processes until the holder dies.
    true = :global.set_lock({{__MODULE__, key}, self()}, [node()], :infinity)
    :ok
  end
end
