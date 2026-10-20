defmodule SpruceGoose.Kernel.Locks do
  @moduledoc """
  Port for transaction-scoped mutual exclusion on a named key.

  A lock taken through this port is held until the surrounding transaction
  ends. Callers name what they serialise (a deployment, an environment, a
  stream) and never how; the adapter decides. PostgreSQL implements it with
  advisory locks; the in-memory adapter serialises within one node.
  """

  @callback acquire(key :: String.t()) :: :ok

  @doc "Take the configured adapter's lock on `key` for the rest of the transaction."
  def acquire(key) when is_binary(key) and key != "", do: adapter().acquire(key)

  def adapter,
    do: Application.get_env(:spruce_goose, :lock_adapter, SpruceGoose.Kernel.Postgres.Locks)
end
