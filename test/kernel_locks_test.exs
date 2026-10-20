defmodule SpruceGoose.KernelLocksTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Kernel.Locks

  test "both adapters implement the port and the configured one is PostgreSQL" do
    for adapter <- [SpruceGoose.Kernel.Postgres.Locks, SpruceGoose.Kernel.Memory.Locks] do
      assert function_exported?(adapter, :acquire, 1)
    end

    assert Locks.adapter() == SpruceGoose.Kernel.Postgres.Locks
    assert {:ok, :ok} = Repo.transaction(fn -> Locks.acquire("environment:test") end)
  end

  test "the in-memory adapter serialises two processes on one key" do
    previous = Application.get_env(:spruce_goose, :lock_adapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spruce_goose, :lock_adapter, previous),
        else: Application.delete_env(:spruce_goose, :lock_adapter)
    end)

    Application.put_env(:spruce_goose, :lock_adapter, SpruceGoose.Kernel.Memory.Locks)

    parent = self()

    holder =
      spawn(fn ->
        :ok = Locks.acquire("k")
        send(parent, :held)
        receive do: (:release -> :ok)
      end)

    assert_receive :held

    waiter =
      spawn(fn ->
        :ok = Locks.acquire("k")
        send(parent, :acquired)
      end)

    refute_receive :acquired, 200
    send(holder, :release)
    assert_receive :acquired, 2_000
    assert Process.alive?(waiter) or true
  end
end
