defmodule SpruceGoose.PR18AuditRegressionsTest do
  use SpruceGoose.DataCase, async: false
  import Ecto.Query

  alias SpruceGoose.Actors.{Actor, Grant, Registry}
  alias SpruceGoose.AgentHooks.{Delivery, OutboxHook, Run, Store, TriageResult}
  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Outbox.{Dispatcher, Event}

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

    keys = [
      :inbox_triage_enabled,
      :inbox_triage_actor_id,
      :inbox_triage_handler,
      :inbox_triage_timeout_ms,
      :outbox_handler
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:spruce_goose, &1)})

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:spruce_goose, key, value) end)
    end)

    proposer =
      Ash.create!(
        Actor,
        %{
          name: "audit-triage-" <> Ecto.UUID.generate(),
          kind: :agent,
          created_by: "isolated-audit"
        }, authorize?: false)

    Ash.create!(
      Grant,
      %{actor_id: proposer.id, role: :proposer, scope: "*", granted_by: "isolated-audit"},
      authorize?: false
    )

    Application.put_env(:spruce_goose, :inbox_triage_enabled, true)
    Application.put_env(:spruce_goose, :inbox_triage_actor_id, proposer.id)
    Application.put_env(:spruce_goose, :inbox_triage_handler, Handler)
    Application.put_env(:spruce_goose, :inbox_triage_timeout_ms, 1_000)
    %{proposer: proposer}
  end

  test "revocation before scheduling exhausts the original event without calling the primary handler",
       %{proposer: proposer} do
    event = capture()
    parent = self()

    Application.put_env(:spruce_goose, :outbox_handler, fn e ->
      send(parent, {:primary_delivery, e.id})
      :ok
    end)

    admin = Ash.get!(Actor, %{name: "test-system"}, authorize?: false)
    assert {:ok, _} = Registry.revoke(proposer.name, "proposer", "*", admin)

    for _ <- 1..20 do
      Repo.update_all(from(e in Event, where: e.id == ^event.id),
        set: [available_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert :ok = Dispatcher.perform(%Oban.Job{})
    end

    refute_received {:primary_delivery, _}
    stored = Repo.get!(Event, event.id)
    assert stored.status == :failed
    assert stored.attempts == 20
    assert stored.last_error =~ "invalid_capture_or_proposer"
    assert [] == Ash.read!(Run, authorize?: false)

    IO.puts(
      "AUDIT_CONFIRMED outbox: revoked hook actor prevents all 20 primary deliveries; event ends failed"
    )
  end

  test "the proposed-result check accepts a NULL digest and permits terminal completion" do
    run = schedule()

    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               """
               INSERT INTO inbox_triage_results
                 (id, run_id, actor_id, context_digest, outcome, proposal, proposal_digest)
               SELECT gen_random_uuid(), id, actor_id, context_digest, 'proposed', '{}'::jsonb, NULL
               FROM agent_hook_runs WHERE id = $1
               """,
               [Ecto.UUID.dump!(run.id)]
             )

    assert :ok = Store.complete_delivery(run.id)
    result = Ash.get!(TriageResult, %{run_id: run.id}, authorize?: false)
    assert result.outcome == :proposed
    assert result.proposal == %{}
    assert result.proposal_digest == nil
    assert Repo.get!(Delivery, run.id).completed_at

    IO.puts(
      "AUDIT_CONFIRMED evidence: NULL proposed digest passes typed constraint and completion guard"
    )
  end

  test "the failed-result check accepts a NULL reason and permits terminal completion" do
    run = schedule()

    assert {:ok, %{num_rows: 1}} =
             Repo.query(
               """
               INSERT INTO inbox_triage_results (id, run_id, actor_id, context_digest, outcome, reason)
               SELECT gen_random_uuid(), id, actor_id, context_digest, 'failed', NULL
               FROM agent_hook_runs WHERE id = $1
               """,
               [Ecto.UUID.dump!(run.id)]
             )

    assert :ok = Store.complete_delivery(run.id)
    result = Ash.get!(TriageResult, %{run_id: run.id}, authorize?: false)
    assert result.outcome == :failed
    assert result.reason == nil
    assert Repo.get!(Delivery, run.id).completed_at

    IO.puts(
      "AUDIT_CONFIRMED evidence: NULL failed reason passes typed constraint and completion guard"
    )
  end

  defp capture do
    assert {:ok, capture} = Executor.run({:add_inbox, "Isolated PR 18 audit specimen"})
    Repo.one!(from(e in Event, where: e.aggregate_id == ^capture.id))
  end

  defp schedule do
    event = capture()
    assert :ok = OutboxHook.deliver(event)
    Ash.read_one!(Run |> Ash.Query.filter_input(event_id: event.id), authorize?: false)
  end
end
