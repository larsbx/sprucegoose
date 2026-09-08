defmodule SpruceGoose.RuntimeShadowSeparateSessionsTest do
  use ExUnit.Case, async: false

  require Ash.Query

  @moduletag :separate_sessions

  alias SpruceGoose.{Authz, Repo}
  alias SpruceGoose.Runtime.{Shadow, ShadowSnapshot}
  alias SpruceGoose.Workflows.{Project, Roadmap, Workflow}
  alias SpruceGoose.Workflows.Task, as: WorkflowTask

  setup do
    SpruceGoose.SandboxMode.set(:auto)
    on_exit(fn -> SpruceGoose.SandboxMode.set(:manual) end)
    :ok
  end

  test "concurrent adapters import one immutable revision" do
    task = governed_task()
    operator = actor_with_operator_role()
    parent = self()

    envelope = %{
      protocol_version: 1,
      adapter: "example-runtime/v1",
      external_id: "concurrent-run-#{task.task_id}",
      revision: 9,
      status: :waiting,
      checkpoint: "approval",
      owner_context_digest: digest("owner"),
      state_digest: digest("state"),
      wait_digest: digest("wait"),
      child_task_count: 1
    }

    contenders =
      for _ <- 1..8 do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:go -> Authz.with_actor(operator, fn -> Shadow.import(task, envelope) end))
        end)
      end

    pids =
      for _ <- contenders,
          do:
            (
              assert_receive {:ready, pid}, 5_000
              pid
            )

    Enum.each(pids, &send(&1, :go))
    results = Enum.map(contenders, &Task.await(&1, 15_000))

    assert Enum.count(results, &match?({:ok, %{created: true}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{created: false}}, &1)) == 7

    snapshots =
      ShadowSnapshot
      |> Ash.Query.filter_input(
        adapter: envelope.adapter,
        external_id: envelope.external_id,
        revision: envelope.revision
      )
      |> Ash.read!(authorize?: false)

    assert length(snapshots) == 1
  end

  defp digest(value), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  defp governed_task do
    suffix = System.unique_integer([:positive])

    project =
      Ash.create!(Project, %{key: "runtime-race-#{suffix}", name: "Runtime"}, authorize?: false)

    roadmap =
      Ash.create!(Roadmap, %{project_id: project.id, key: "roadmap", name: "Roadmap"},
        authorize?: false
      )

    workflow =
      Ash.create!(
        Workflow,
        %{
          roadmap_id: roadmap.id,
          workflow_id: "workflow",
          name: "Workflow",
          definition: %{"tasks" => [%{"id" => "shadow", "kind" => "oban"}]}
        },
        authorize?: false
      )

    Ash.create!(
      WorkflowTask,
      %{
        task_id: SpruceGoose.TaskId.generate(),
        title: "Shadow",
        workflow_id: workflow.id,
        runner: :oban,
        priority: 0,
        definition_of_done: "Concurrent shadow import is singular"
      },
      authorize?: false
    )
  end

  defp actor_with_operator_role do
    suffix = System.unique_integer([:positive])

    actor =
      Ash.create!(
        SpruceGoose.Actors.Actor,
        %{name: "runtime-race-operator-#{suffix}", kind: :agent, created_by: "test"},
        authorize?: false
      )

    Ash.create!(
      SpruceGoose.Actors.Grant,
      %{actor_id: actor.id, role: :operator, scope: "*", granted_by: "test"},
      authorize?: false
    )

    actor
  end
end
