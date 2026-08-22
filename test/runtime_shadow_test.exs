defmodule SpruceGoose.RuntimeShadowTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Authz
  alias SpruceGoose.Runtime.ShadowSnapshot
  alias SpruceGoose.Runtime.Shadow
  alias SpruceGoose.Workflows.{Project, Roadmap, Task, Workflow}

  test "imports an immutable provider-neutral runtime envelope without taking authority" do
    task = governed_task("shadow")
    operator = actor_with_role("runtime-shadow-operator", :operator)

    attrs = %{
      task_id: task.id,
      protocol_version: 1,
      adapter: "example-runtime/v1",
      external_id: "run-shadow-1",
      revision: 7,
      status: :waiting,
      checkpoint: "await_reply",
      owner_context_digest: digest("owner-context"),
      state_digest: digest("state"),
      wait_digest: digest("wait"),
      child_task_count: 2
    }

    assert {:ok, snapshot} =
             as_actor(operator, fn ->
               Authz.create(ShadowSnapshot, attrs, action: :import)
             end)

    assert snapshot.external_id == attrs.external_id
    assert snapshot.revision == 7

    assert {:ok, other_adapter} =
             as_actor(operator, fn ->
               Authz.create(
                 ShadowSnapshot,
                 %{attrs | adapter: "replacement-runtime/v1"},
                 action: :import
               )
             end)

    assert other_adapter.external_id == snapshot.external_id

    assert {:error, duplicate} =
             as_actor(operator, fn ->
               Authz.create(ShadowSnapshot, %{attrs | status: "running"}, action: :import)
             end)

    assert Exception.message(duplicate) =~ "already"
    assert is_nil(Ash.Resource.Info.action(ShadowSnapshot, :update))
    assert is_nil(Ash.Resource.Info.action(ShadowSnapshot, :destroy))

    assert {:error,
            %Postgrex.Error{postgres: %{message: "runtime shadow snapshots are immutable"}}} =
             Ecto.Adapters.SQL.query(
               SpruceGoose.Repo,
               "UPDATE runtime_shadow_snapshots SET status = 'running' WHERE id = $1::uuid",
               [Ecto.UUID.dump!(snapshot.id)],
               mode: :savepoint
             )
  end

  test "imports idempotently, refuses revision conflicts, and reports parity" do
    task = governed_task("adapter")
    operator = actor_with_role("runtime-adapter-operator", :operator)

    envelope = %{
      protocol_version: 1,
      adapter: "example-runtime/v1",
      external_id: "run-adapter-1",
      revision: 3,
      status: "waiting",
      checkpoint: "approval",
      owner_context_digest: digest("owner"),
      state_digest: digest("state"),
      wait_digest: digest("wait"),
      child_task_count: 1
    }

    as_actor(operator, fn ->
      assert {:ok, %{created: true}} = Shadow.import(task, envelope)
      assert {:ok, %{parity: true, mismatches: []}} = Shadow.parity(task, envelope)
      assert {:ok, %{created: false}} = Shadow.import(task, envelope)

      changed = %{envelope | status: :running}

      assert {:error, "runtime revision conflicts with immutable snapshot"} =
               Shadow.import(task, changed)

      assert {:ok, %{parity: false, mismatches: [:status]}} = Shadow.parity(task, changed)
    end)
  end

  test "the runtime port and persistence contract contain no provider names" do
    root = Path.expand("..", __DIR__)

    source =
      [
        "lib/spruce_goose/runtime/state_source.ex",
        "lib/spruce_goose/runtime/shadow_snapshot.ex",
        "priv/repo/migrations/20260822210819_runtime_shadow_snapshots.exs"
      ]
      |> Enum.map_join("\n", &File.read!(Path.join(root, &1)))

    refute source =~ "TaskFlow"
    refute source =~ "OpenClaw"
    refute source =~ "Pi agent"
  end

  defp digest(value), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  defp governed_task(suffix) do
    {:ok, project} =
      Ash.create(Project, %{key: "runtime-#{suffix}", name: "Runtime"}, authorize?: false)

    {:ok, roadmap} =
      Ash.create(Roadmap, %{project_id: project.id, key: "roadmap", name: "Roadmap"},
        authorize?: false
      )

    {:ok, workflow} =
      Ash.create(
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
      Task,
      %{
        task_id: SpruceGoose.TaskId.generate(),
        title: "Shadow",
        workflow_id: workflow.id,
        runner: :oban,
        priority: 0,
        definition_of_done: "Shadow parity passes"
      },
      authorize?: false
    )
  end

  defp actor_with_role(name, role) do
    actor =
      Ash.create!(
        SpruceGoose.Actors.Actor,
        %{name: name, kind: :agent, created_by: "test"},
        authorize?: false
      )

    Ash.create!(
      SpruceGoose.Actors.Grant,
      %{actor_id: actor.id, role: role, scope: "*", granted_by: "test"},
      authorize?: false
    )

    actor
  end

  defp as_actor(actor, fun), do: SpruceGoose.Authz.with_actor(actor, fun)
end
