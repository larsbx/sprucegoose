defmodule SpruceGoose.TaskFlowShadowTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Authz
  alias SpruceGoose.TaskFlow.ShadowSnapshot
  alias SpruceGoose.Workflows.{Project, Roadmap, Task, Workflow}

  test "imports immutable revisioned TaskFlow state without taking runtime authority" do
    task = governed_task("shadow")
    operator = actor_with_role("taskflow-shadow-operator", :operator)

    attrs = %{
      task_id: task.id,
      flow_id: "flow-shadow-1",
      revision: 7,
      sync_mode: "managed",
      status: "waiting",
      owner_key: "agent:main:telegram:direct:8071938660",
      current_step: "await_reply",
      state_digest: digest("state"),
      wait_digest: digest("wait"),
      child_task_count: 2
    }

    assert {:ok, snapshot} =
             as_actor(operator, fn ->
               Authz.create(ShadowSnapshot, attrs, action: :import)
             end)

    assert snapshot.flow_id == attrs.flow_id
    assert snapshot.revision == 7

    assert {:error, duplicate} =
             as_actor(operator, fn ->
               Authz.create(ShadowSnapshot, %{attrs | status: "running"}, action: :import)
             end)

    assert Exception.message(duplicate) =~ "already"
    assert is_nil(Ash.Resource.Info.action(ShadowSnapshot, :update))
    assert is_nil(Ash.Resource.Info.action(ShadowSnapshot, :destroy))

    assert {:error,
            %Postgrex.Error{postgres: %{message: "TaskFlow shadow snapshots are immutable"}}} =
             Ecto.Adapters.SQL.query(
               SpruceGoose.Repo,
               "UPDATE taskflow_shadow_snapshots SET status = 'running' WHERE id = $1::uuid",
               [Ecto.UUID.dump!(snapshot.id)],
               mode: :savepoint
             )
  end

  defp digest(value), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  defp governed_task(suffix) do
    {:ok, project} =
      Ash.create(Project, %{key: "tf-#{suffix}", name: "TaskFlow"}, authorize?: false)

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
          definition: %{"tasks" => [%{"id" => "shadow", "kind" => "taskflow"}]}
        },
        authorize?: false
      )

    Ash.create!(
      Task,
      %{
        task_id: SpruceGoose.TaskId.generate(),
        title: "Shadow",
        workflow_id: workflow.id,
        runner: :taskflow,
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
