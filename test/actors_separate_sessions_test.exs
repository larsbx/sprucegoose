defmodule SpruceGoose.ActorsSeparateSessionsTest do
  use ExUnit.Case, async: false

  @moduletag :separate_sessions

  alias SpruceGoose.Actors.{Actor, Grant, Registry, Resolver}
  alias SpruceGoose.Repo

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    clear_registry()
    previous_expected = Application.get_env(:spruce_goose, :expected_genesis_actor)
    Application.delete_env(:spruce_goose, :expected_genesis_actor)

    on_exit(fn ->
      clear_registry()

      if previous_expected do
        Application.put_env(:spruce_goose, :expected_genesis_actor, previous_expected)
      else
        Application.delete_env(:spruce_goose, :expected_genesis_actor)
      end

      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "concurrent Genesis requests on separate database sessions admit one complete actor" do
    parent = self()

    contenders =
      for index <- 1..4 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go ->
              Registry.add(
                %{name: "separate-genesis-#{index}", kind: :human, description: nil},
                nil
              )
          end
        end)
      end

    pids =
      for _ <- contenders do
        assert_receive {:ready, pid}, 5_000
        pid
      end

    Enum.each(pids, &send(&1, :go))
    results = Enum.map(contenders, &Task.await(&1, 15_000))
    actors = Ash.read!(Actor, authorize?: false)
    grants = Ash.read!(Grant, authorize?: false)

    assert Enum.count(results, &match?({:ok, %{genesis: true}}, &1)) == 1
    assert length(actors) == 1
    assert length(grants) == 7
    assert Enum.all?(grants, &(&1.actor_id == hd(actors).id and &1.granted_by == "genesis"))
  end

  test "a request waiting on the registry lock reloads authority after another session revokes it" do
    admin_a = create_actor!("separate-admin-a")
    admin_b = create_actor!("separate-admin-b")
    create_admin_grant!(admin_a)
    create_admin_grant!(admin_b)
    assert {:ok, stale_admin_a} = Resolver.resolve(admin_a.name)
    assert {:ok, current_admin_b} = Resolver.resolve(admin_b.name)
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
            "sprucegoose:actor-registry-write"
          ])

          send(parent, {:holder_ready, self()})

          receive do
            :revoke ->
              Registry.revoke(admin_a.name, "admin", "*", current_admin_b)
          end
        end)
      end)

    assert_receive {:holder_ready, holder_pid}, 5_000

    requester =
      Task.async(fn ->
        Registry.add(
          %{name: "must-not-commit", kind: :agent, description: nil},
          stale_admin_a
        )
      end)

    assert wait_for_advisory_waiter()
    send(holder_pid, :revoke)
    assert {:ok, {:ok, _revoked}} = Task.await(holder, 10_000)

    assert {:error, message} = Task.await(requester, 10_000)
    assert message =~ "does not hold admin"
    refute Enum.any?(Ash.read!(Actor, authorize?: false), &(&1.name == "must-not-commit"))
  end

  defp wait_for_advisory_waiter(attempts \\ 50)

  defp wait_for_advisory_waiter(0), do: false

  defp wait_for_advisory_waiter(attempts) do
    %{rows: [[waiting]]} =
      Repo.query!("""
      SELECT count(*)
      FROM pg_stat_activity
      WHERE datname = current_database()
        AND pid <> pg_backend_pid()
        AND wait_event_type = 'Lock'
        AND wait_event = 'advisory'
      """)

    if waiting > 0 do
      true
    else
      Process.sleep(50)
      wait_for_advisory_waiter(attempts - 1)
    end
  end

  defp create_actor!(name) do
    Ash.create!(
      Actor,
      %{name: name, kind: :human, created_by: "separate-session-test"},
      authorize?: false
    )
  end

  defp create_admin_grant!(actor) do
    Ash.create!(
      Grant,
      %{actor_id: actor.id, role: :admin, scope: "*", granted_by: "separate-session-test"},
      authorize?: false
    )
  end

  defp clear_registry do
    Repo.delete_all(Grant)
    Repo.delete_all(Actor)
  end
end
