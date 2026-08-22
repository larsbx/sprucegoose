defmodule SpruceGoose.GrandfatheredBaselineTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Kernel.Postgres.EventLedger
  alias SpruceGoose.Repo

  setup do
    Repo.query!(
      "TRUNCATE replay_projections, grandfathered_baselines, certified_events RESTART IDENTITY"
    )

    :ok
  end

  test "accepts exactly one content-addressed baseline at the next certified position" do
    task = task_fixture()
    assert {:ok, _} = Executor.run({:link_task, task.task_id, "evidence", "before-baseline"})

    assert {:ok, baseline} = Executor.run(:accept_grandfathered_baseline)
    assert baseline.legacy_final_stream_position == 1
    assert baseline.acceptance_stream_position == 2
    assert byte_size(baseline.snapshot_digest) == 64

    assert {:ok, shown} = Executor.run(:show_grandfathered_baseline)
    assert shown == baseline

    assert {:ok, events} = EventLedger.read(EventLedger.new(), "authority:sprucegoose")
    assert Enum.map(events, & &1.event_type) == ["MutationAccepted", "GrandfatheredStateAccepted"]

    assert List.last(events).payload["snapshot_content_id"] ==
             "sha256:" <> baseline.snapshot_digest

    assert {:error, :baseline_already_accepted} = Executor.run(:accept_grandfathered_baseline)
    assert {:ok, events_after} = EventLedger.read(EventLedger.new(), "authority:sprucegoose")
    assert length(events_after) == 2
  end

  test "snapshot bytes and row are immutable and credential relations are excluded" do
    assert {:ok, baseline} = Executor.run(:accept_grandfathered_baseline)

    assert %{rows: [[snapshot, bytes]]} =
             Repo.query!("SELECT snapshot, canonical_bytes FROM grandfathered_baselines")

    refute Map.has_key?(snapshot["tables"], "users")
    assert :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) == baseline.snapshot_digest

    assert_raise Postgrex.Error, ~r/grandfathered baselines are immutable/, fn ->
      Repo.query!("UPDATE grandfathered_baselines SET snapshot = '{}'::jsonb")
    end

    assert_raise Postgrex.Error, ~r/grandfathered baselines are immutable/, fn ->
      Repo.query!("DELETE FROM grandfathered_baselines")
    end
  end

  test "root-policy refusal rolls the baseline and event back" do
    previous = Application.get_env(:spruce_goose, :shadow_event_policy_path)
    Application.put_env(:spruce_goose, :shadow_event_policy_path, "/absent/baseline-roots.json")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spruce_goose, :shadow_event_policy_path, previous),
        else: Application.delete_env(:spruce_goose, :shadow_event_policy_path)
    end)

    assert {:error, :shadow_roots_unavailable} = Executor.run(:accept_grandfathered_baseline)
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM grandfathered_baselines")
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM certified_events")
  end

  test "unreconciled shadow history refuses the baseline" do
    task = task_fixture()
    assert {:ok, _} = Executor.run({:link_task, task.task_id, "evidence", "covered"})

    current = Ash.get!(SpruceGoose.Workflows.Task, task.id)

    current
    |> Ash.Changeset.for_update(:revise, %{description: "test-only bypass"})
    |> Ash.update!()

    assert {:error, :shadow_not_reconciled} = Executor.run(:accept_grandfathered_baseline)
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM grandfathered_baselines")
    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM certified_events")
  end

  test "rebuilds authoritative task state, proves parity, and refuses direct writes" do
    task = task_fixture()
    assert {:ok, _} = Executor.run(:accept_grandfathered_baseline)
    assert {:ok, _} = Executor.run({:link_task, task.task_id, "evidence", "after-baseline"})

    assert {:ok, rebuilt} = Executor.run(:rebuild_task_projection)
    assert rebuilt.tasks >= 1

    assert {:ok, %{parity: true, lag: 0}} = Executor.run(:task_projection_status)

    assert_raise Postgrex.Error, ~r/replay projections are projector-owned/, fn ->
      Repo.query!("UPDATE replay_projections SET stream_position = stream_position + 1")
    end

    Repo.query!("SELECT set_config('sprucegoose.projector_write', 'on', true)")
    Repo.query!("DELETE FROM replay_projections")
    assert {:error, :projection_not_built} = Executor.run(:task_projection_status)

    assert {:ok, rebuilt_again} = Executor.run(:rebuild_task_projection)
    assert rebuilt_again.state_digest == rebuilt.state_digest
  end

  @tag :separate_sessions
  test "acceptance racing a supported mutation keeps one contiguous boundary" do
    parent = self()
    task = task_fixture()

    [mutation, acceptance] =
      [
        fn -> Executor.run({:link_task, task.task_id, "evidence", "racing"}) end,
        fn -> Executor.run(:accept_grandfathered_baseline) end
      ]
      |> Task.async_stream(
        fn operation ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
          operation.()
        end,
        max_concurrency: 2,
        timeout: 15_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert match?({:ok, _}, mutation)
    assert match?({:ok, _}, acceptance)

    assert %{rows: [[1], [2]]} =
             Repo.query!("SELECT stream_position FROM certified_events ORDER BY stream_position")

    assert {:ok, baseline} = Executor.run(:show_grandfathered_baseline)
    assert baseline.acceptance_stream_position in [1, 2]
  end

  defp task_fixture do
    suffix = System.unique_integer([:positive])

    project =
      Ash.create!(SpruceGoose.Workflows.Project, %{key: "baseline-#{suffix}", name: "Baseline"})

    roadmap =
      Ash.create!(SpruceGoose.Workflows.Roadmap, %{
        project_id: project.id,
        key: "baseline-#{suffix}",
        name: "Baseline"
      })

    workflow =
      Ash.create!(SpruceGoose.Workflows.Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "baseline-#{suffix}",
        name: "Baseline",
        definition: %{
          schema_version: 1,
          tasks: [%{id: "work", kind: :openclaw, depends_on: [], input: %{}}]
        }
      })

    Ash.create!(SpruceGoose.Workflows.Task, %{
      workflow_id: workflow.id,
      task_id: SpruceGoose.TaskId.generate(),
      task_type: :task,
      title: "Baseline task",
      definition_of_done: "Baseline proof passes.",
      runner: :openclaw
    })
  end
end
