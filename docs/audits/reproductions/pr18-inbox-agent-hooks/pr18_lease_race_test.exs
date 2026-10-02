defmodule SpruceGoose.PR18LeaseRaceAuditTest do
  use ExUnit.Case, async: false
  @moduletag :separate_sessions
  import Ecto.Query
  alias SpruceGoose.Actors.{Actor, Grant}
  alias SpruceGoose.AgentHooks.{OutboxHook, Store, TriageResult}
  alias SpruceGoose.{Authz, Repo}
  alias SpruceGoose.Outbox.Event
  alias SpruceGoose.Workflows.InboxItem

  defmodule Handler do
    def propose(_), do: {:error, :unused}
  end

  setup do
    # Archived defect reproduction; only the exact audited source in an isolated DB.
    assert System.get_env("SPRUCE_GOOSE_PR18_AUDIT_REPRODUCTION") == "1"
    database = Repo.config()[:database]
    assert is_binary(database) and String.starts_with?(database, "sprucegoose_pr18_audit_")
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    assert String.trim(head) == "f9d136bfa2679a4fb57363afd5dfa2a5b6353f1a"

    assert Repo.config()[:pool] == DBConnection.ConnectionPool,
           "set SPRUCE_GOOSE_TEST_DOGFOOD=true for separate PostgreSQL sessions"

    SpruceGoose.SandboxMode.set(:auto)

    keys = [
      :inbox_triage_enabled,
      :inbox_triage_actor_id,
      :inbox_triage_handler,
      :inbox_triage_timeout_ms
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:spruce_goose, &1)})
    proposer = actor(:proposer)
    operator = actor(:operator)
    Application.put_env(:spruce_goose, :inbox_triage_enabled, true)
    Application.put_env(:spruce_goose, :inbox_triage_actor_id, proposer.id)
    Application.put_env(:spruce_goose, :inbox_triage_handler, Handler)
    Application.put_env(:spruce_goose, :inbox_triage_timeout_ms, 1_000)

    item =
      Authz.with_actor(operator, fn ->
        Authz.create(InboxItem, %{
          capture_id: "audit-lease-" <> Ecto.UUID.generate(),
          body: "Lease boundary specimen"
        })
      end)
      |> elem(1)

    event = Repo.one!(from(e in Event, where: e.aggregate_id == ^item.capture_id))
    assert :ok = OutboxHook.deliver(event)
    [run] = Ash.read!(SpruceGoose.AgentHooks.Run, authorize?: false)
    assert {:ok, {:claimed, _, token, _, _}} = Store.claim(run.id)
    expiry = DateTime.add(DateTime.utc_now(), 2, :second)

    Repo.query!("UPDATE agent_hook_deliveries SET claimed_until = $2 WHERE run_id = $1", [
      Ecto.UUID.dump!(run.id),
      expiry
    ])

    on_exit(fn ->
      Repo.query!("TRUNCATE agent_hook_deliveries, inbox_triage_results, agent_hook_runs")
      Repo.delete_all(from(j in Oban.Job, where: j.worker == "SpruceGoose.AgentHooks.Worker"))
      Repo.delete_all(from(e in Event, where: e.id == ^event.id))
      Repo.delete_all(from(i in "inbox_items", where: i.id == ^Ecto.UUID.dump!(item.id)))

      for a <- [proposer, operator] do
        Repo.delete_all(from(g in Grant, where: g.actor_id == ^a.id))
        Ash.destroy!(a, authorize?: false)
      end

      Enum.each(previous, fn {k, v} -> Application.put_env(:spruce_goose, k, v) end)
      SpruceGoose.SandboxMode.set(:manual)
    end)

    %{run: run, item: item, token: token, proposer: proposer, expiry: expiry}
  end

  test "a direct Ash submission can commit after its lease expires while waiting on the capture row",
       c do
    outcome =
      delayed_submission(c, fn ->
        Authz.with_actor(c.proposer, fn ->
          Authz.create_with_notifications(
            TriageResult,
            %{run_id: c.run.id, claim_id: c.token, proposal: proposal()},
            action: :submit
          )
        end)
      end)

    assert {:ok, result, notifications} = outcome
    Ash.Notifier.notify(notifications)
    assert result.outcome == :proposed
    assert DateTime.compare(DateTime.utc_now(), c.expiry) == :gt

    IO.puts(
      "AUDIT_CONFIRMED lease: direct Ash submit commits an expired claim after waiting on the capture row"
    )
  end

  test "the worker Store.finish path refuses the same expiry after the capture-row wait", c do
    outcome = delayed_submission(c, fn -> Store.finish(c.run.id, c.token, {:ok, proposal()}) end)
    assert {:error, _} = outcome
    assert [] == Ash.read!(TriageResult, authorize?: false)

    IO.puts(
      "AUDIT_CONTROL lease: Store.finish rechecks the expired claim and rolls the submission back"
    )
  end

  defp delayed_submission(c, submit) do
    parent = self()

    holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT id FROM inbox_items WHERE id = $1 FOR UPDATE", [
            Ecto.UUID.dump!(c.item.id)
          ])

          send(parent, {:locked, self()})
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive {:locked, pid}, 5_000
    task = Task.async(submit)
    assert waiter?(50)
    wait_ms = max(DateTime.diff(c.expiry, DateTime.utc_now(), :millisecond) + 100, 1)
    Process.sleep(wait_ms)
    assert DateTime.compare(DateTime.utc_now(), c.expiry) == :gt
    send(pid, :release)
    assert {:ok, :ok} = Task.await(holder, 5_000)
    Task.await(task, 5_000)
  end

  defp waiter?(0), do: false

  defp waiter?(attempts) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND wait_event_type = 'Lock' AND wait_event = 'transactionid'"
      )

    if count > 0,
      do: true,
      else:
        (
          Process.sleep(20)
          waiter?(attempts - 1)
        )
  end

  defp actor(role) do
    a =
      Ash.create!(
        Actor,
        %{
          name: "audit-lease-" <> Ecto.UUID.generate(),
          kind: :agent,
          created_by: "isolated-audit"
        },
        authorize?: false
      )

    Ash.create!(Grant, %{actor_id: a.id, role: role, scope: "*", granted_by: "isolated-audit"},
      authorize?: false
    )

    a
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
end
