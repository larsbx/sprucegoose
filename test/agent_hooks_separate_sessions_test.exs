defmodule SpruceGoose.AgentHooksSeparateSessionsTest do
  use ExUnit.Case, async: false
  @moduletag :separate_sessions
  import Ecto.Query

  alias SpruceGoose.Actors.{Actor, Grant, Registry}
  alias SpruceGoose.AgentHooks.{OutboxHook, Run, Store, TriageResult}
  alias SpruceGoose.{Authz, Repo}
  alias SpruceGoose.Outbox.Event
  alias SpruceGoose.Workflows.InboxItem

  defmodule Handler do
    def propose(_), do: {:error, :not_used}
  end

  setup do
    SpruceGoose.SandboxMode.set(:auto)
    keys = [:inbox_triage_enabled, :inbox_triage_actor_id, :inbox_triage_handler]
    previous = Map.new(keys, &{&1, Application.get_env(:spruce_goose, &1)})
    proposer = actor(:proposer)
    operator = actor(:operator)
    admin = actor(:admin)
    Application.put_env(:spruce_goose, :inbox_triage_enabled, true)
    Application.put_env(:spruce_goose, :inbox_triage_actor_id, proposer.id)
    Application.put_env(:spruce_goose, :inbox_triage_handler, Handler)
    capture_id = "triage-race-" <> Ecto.UUID.generate()

    item =
      Authz.with_actor(operator, fn ->
        Authz.create(InboxItem, %{capture_id: capture_id, body: "Concurrency evidence"})
      end)
      |> elem(1)

    event = Repo.one!(from(e in Event, where: e.aggregate_id == ^capture_id))

    on_exit(fn ->
      # This group owns a disposable test database. TRUNCATE is intentionally
      # confined to test cleanup; runtime has no deletion action for evidence.
      Repo.query!("TRUNCATE agent_hook_deliveries, inbox_triage_results, agent_hook_runs")
      Repo.delete_all(from(j in Oban.Job, where: j.worker == "SpruceGoose.AgentHooks.Worker"))
      Repo.delete_all(from(e in Event, where: e.id == ^event.id))
      Repo.delete_all(from(i in "inbox_items", where: i.id == ^Ecto.UUID.dump!(item.id)))

      for actor <- [proposer, operator, admin] do
        Repo.delete_all(from(g in Grant, where: g.actor_id == ^actor.id))
        Ash.destroy!(actor, authorize?: false)
      end

      Enum.each(previous, fn {key, value} -> Application.put_env(:spruce_goose, key, value) end)
      SpruceGoose.SandboxMode.set(:manual)
    end)

    %{proposer: proposer, operator: operator, admin: admin, item: item, event: event}
  end

  test "concurrent deliveries and claims converge on one run, job, and terminal result", %{
    event: event
  } do
    assert Enum.all?(race(8, fn -> OutboxHook.deliver(event) end), &(&1 == :ok))
    [run] = Ash.read!(Run, authorize?: false)

    assert [%{args: %{"run_id" => id}}] =
             Repo.all(from(j in Oban.Job, where: j.worker == "SpruceGoose.AgentHooks.Worker"))

    assert id == run.id
    claims = race(8, fn -> Store.claim(run.id) end)

    assert [{:ok, {:claimed, _, token, _, _}}] =
             Enum.filter(claims, &match?({:ok, {:claimed, _, _, _, _}}, &1))

    assert Enum.count(claims, &match?({:ok, {:busy, _}}, &1)) == 7
    assert {:ok, _} = Store.finish(run.id, token, {:ok, proposal()})
    assert length(Ash.read!(TriageResult, authorize?: false)) == 1
  end

  test "submission waiting behind a committed revocation re-reads the grant", %{
    event: event,
    proposer: proposer,
    admin: admin
  } do
    {run, token} = claim(event)
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
            "sprucegoose:actor-registry-write"
          ])

          send(parent, {:locked, self()})
          receive do: (:revoke -> Registry.revoke(proposer.name, "proposer", "*", admin))
        end)
      end)

    assert_receive {:locked, pid}, 5_000
    submitter = Task.async(fn -> Store.finish(run.id, token, {:ok, proposal()}) end)
    assert waiter?("advisory")
    send(pid, :revoke)
    assert {:ok, {:ok, _}} = Task.await(holder)
    assert {:ok, :refused} = Task.await(submitter)

    assert %{outcome: :refused, reason: "proposer_revoked_or_overprivileged", proposal: nil} =
             result(run)
  end

  test "submission waiting on the inbox row sees the committed resolution", %{
    event: event,
    item: item,
    operator: operator
  } do
    {run, token} = claim(event)
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM inbox_items WHERE id = $1 FOR UPDATE", [
            Ecto.UUID.dump!(item.id)
          ])

          send(parent, {:locked, self()})

          receive do
            :resolve ->
              Authz.with_actor(operator, fn ->
                Authz.update_with_notifications(item, %{to_state: :resolved}, action: :resolve)
              end)
          end
        end)
      end)

    assert_receive {:locked, pid}, 5_000
    submitter = Task.async(fn -> Store.finish(run.id, token, {:ok, proposal()}) end)
    assert waiter?("transactionid")
    send(pid, :resolve)
    assert {:ok, {:ok, _, notifications}} = Task.await(holder)
    Ash.Notifier.notify(notifications)
    assert {:ok, :refused} = Task.await(submitter)
    assert %{outcome: :refused, reason: "stale_capture", proposal: nil} = result(run)
  end

  defp race(count, fun) do
    parent = self()

    tasks =
      for _ <- 1..count,
          do:
            Task.async(fn ->
              send(parent, {:ready, self()})
              receive do: (:go -> fun.())
            end)

    pids =
      for _ <- tasks do
        assert_receive {:ready, pid}, 5_000
        pid
      end

    Enum.each(pids, &send(&1, :go))

    Task.await_many(tasks, 15_000)
  end

  defp waiter?(event, attempts \\ 50)
  defp waiter?(_event, 0), do: false

  defp waiter?(event, attempts) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND wait_event_type = 'Lock' AND wait_event = $1",
        [event]
      )

    if count > 0,
      do: true,
      else:
        (
          Process.sleep(20)
          waiter?(event, attempts - 1)
        )
  end

  defp actor(role) do
    actor =
      Ash.create!(
        Actor,
        %{
          name: "triage-race-" <> String.slice(Ecto.UUID.generate(), 0, 12),
          kind: :agent,
          created_by: "test"
        },
        authorize?: false
      )

    Ash.create!(Grant, %{actor_id: actor.id, role: role, scope: "*", granted_by: "test"},
      authorize?: false
    )

    actor
  end

  defp claim(event) do
    assert :ok = OutboxHook.deliver(event)
    [run] = Ash.read!(Run, authorize?: false)
    assert {:ok, {:claimed, _, token, _, _}} = Store.claim(run.id)
    {run, token}
  end

  defp proposal do
    %{
      "disposition" => "drop",
      "project_key" => nil,
      "workflow_key" => nil,
      "rationale" => "Review required",
      "uncertainty" => "high",
      "evidence_refs" => [],
      "draft_task_definition" => nil
    }
  end

  defp result(run), do: Ash.get!(TriageResult, %{run_id: run.id}, authorize?: false)
end
