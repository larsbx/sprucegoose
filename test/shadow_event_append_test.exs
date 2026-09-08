defmodule SpruceGoose.ShadowEventAppendTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.SopGate
  alias SpruceGoose.Kernel.Postgres.EventLedger
  alias SpruceGoose.ReleaseProvenance
  alias SpruceGoose.Repo

  setup do
    Repo.query!("TRUNCATE certified_events RESTART IDENTITY")
    task = task_fixture()
    %{task: task}
  end

  test "an accepted task mutation appends one certified event in the same transaction", %{
    task: task
  } do
    assert {:ok, updated} = Executor.run({:link_task, task.task_id, "evidence", "shadow-proof"})
    assert updated.lock_version > task.lock_version

    assert {:ok, [event]} = EventLedger.read(EventLedger.new(), "authority:sprucegoose")
    assert event.event_type == "MutationAccepted"
    assert event.payload["command"] == "link_task"
    assert event.payload["result"]["id"] == task.task_id
    assert event.payload["outbox_event_key"] =~ "task:#{task.task_id}:"
    outbox_key = event.payload["outbox_event_key"]

    assert %{rows: rows} =
             Repo.query!("SELECT event_key FROM outbox_events WHERE aggregate_id = $1", [
               task.task_id
             ])

    assert [outbox_key] in rows

    assert {:ok, %{reconciled: true, missing_task_events: 0}} =
             Executor.run(:shadow_ledger_status)
  end

  test "a shadow append refusal rolls back the accepted mutation", %{task: task} do
    previous = Application.get_env(:spruce_goose, :shadow_event_policy_path)
    Application.put_env(:spruce_goose, :shadow_event_policy_path, "/absent/shadow-roots.json")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spruce_goose, :shadow_event_policy_path, previous),
        else: Application.delete_env(:spruce_goose, :shadow_event_policy_path)
    end)

    assert {:error, :shadow_roots_unavailable} =
             Executor.run({:link_task, task.task_id, "evidence", "rolled-back"})

    assert {:ok, []} = EventLedger.read(EventLedger.new(), "authority:sprucegoose")
    assert {:ok, current} = Executor.run({:show_task, task.task_id})
    refute %{"kind" => "evidence", "value" => "rolled-back"} in current.references
  end

  test "read-only commands do not append shadow events", %{task: task} do
    assert {:ok, _current} = Executor.run({:show_task, task.task_id})
    assert {:ok, []} = EventLedger.read(EventLedger.new(), "authority:sprucegoose")
  end

  test "reconciliation detects a task mutation that bypassed the shadow wrapper", %{task: task} do
    assert {:ok, _updated} = Executor.run({:link_task, task.task_id, "evidence", "boundary"})

    current = Ash.get!(SpruceGoose.Workflows.Task, task.id)

    current
    |> Ash.Changeset.for_update(:revise, %{description: "direct test-only bypass"})
    |> Ash.update!()

    assert {:ok, %{reconciled: false, missing_task_events: 1}} =
             Executor.run(:shadow_ledger_status)
  end

  test "the reviewed root policy matches its exact source artifacts" do
    policy_path = Application.app_dir(:spruce_goose, "priv/kernel/shadow-event-roots.json")
    policy = policy_path |> File.read!() |> Jason.decode!()
    roots = policy["roots"]

    assert Map.keys(roots) |> Enum.sort() ==
             ~w(agent_charter evidence_policy grant_epoch interpreter norm ontology policy schema)

    assert roots["ontology"] == digest("lib/spruce_goose/kernel/constitution.ex")
    assert roots["interpreter"] == digest("lib/spruce_goose/kernel/constitution.ex")
    assert roots["agent_charter"] == digest("lib/spruce_goose/actors/registry.ex")
    assert roots["grant_epoch"] == digest("lib/spruce_goose/actors/scope.ex")
    assert roots["policy"] == digest("docs/authority-planes.md")
    assert roots["evidence_policy"] == digest("docs/abstract-kernel-remediation-plan.md")

    # The SOP's bytes live in the openclaw-system vault, so this used to digest
    # an absolute path under one operator's home directory — which meant the
    # test that validates the constitutional root set could only run on that one
    # host, and aborted before the `schema` assertion below on every other.
    # `priv/constitution/adopted.json` carries the reviewed digest instead;
    # `SopGate.verify_adoption/0` checks the deployed bytes against it at boot.
    assert {:ok, adopted} = SopGate.adopted_digest()
    assert roots["norm"] == adopted

    migrations =
      "priv/repo/migrations/*.exs"
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&%{"path" => &1, "sha256" => String.replace_prefix(digest(&1), "sha256:", "")})

    assert roots["schema"] == "sha256:" <> ReleaseProvenance.migration_set_digest(migrations)
  end

  @tag :separate_sessions
  test "concurrent accepted mutations retain one contiguous certified position" do
    parent = self()
    tasks = Enum.map(1..12, fn index -> task_fixture("concurrent-#{index}") end)

    results =
      tasks
      |> Task.async_stream(
        fn task ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          Executor.run({:link_task, task.task_id, "evidence", "concurrent"})
        end,
        max_concurrency: 12,
        timeout: 15_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))

    assert %{rows: positions} =
             Repo.query!("SELECT stream_position FROM certified_events ORDER BY stream_position")

    assert Enum.map(positions, &hd/1) == Enum.to_list(1..12)
  end

  defp task_fixture(prefix \\ "shadow") do
    suffix = "#{prefix}-#{System.unique_integer([:positive])}"

    project =
      Ash.create!(SpruceGoose.Workflows.Project, %{key: "shadow-#{suffix}", name: "Shadow"})

    roadmap =
      Ash.create!(SpruceGoose.Workflows.Roadmap, %{
        project_id: project.id,
        key: "shadow-#{suffix}",
        name: "Shadow"
      })

    workflow =
      Ash.create!(SpruceGoose.Workflows.Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "shadow-#{suffix}",
        name: "Shadow",
        definition: %{
          schema_version: 1,
          tasks: [%{id: "work", kind: :openclaw, depends_on: [], input: %{}}]
        }
      })

    Ash.create!(SpruceGoose.Workflows.Task, %{
      workflow_id: workflow.id,
      task_id: SpruceGoose.TaskId.generate(),
      task_type: :task,
      title: "Shadow task",
      definition_of_done: "Shadow proof passes.",
      runner: :openclaw
    })
  end

  defp digest(path) do
    "sha256:" <> (:crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower))
  end
end
