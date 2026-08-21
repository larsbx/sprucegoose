defmodule SpruceGoose.DerivationsTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Actors.{Actor, Grant}
  alias SpruceGoose.Authz
  alias SpruceGoose.Derivations.{Domain, Executor, Permit}
  alias SpruceGoose.Workflows.{Definition, Project, Roadmap, Task, Workflow}

  @commit String.duplicate("a", 40)
  @tree String.duplicate("b", 40)
  @pipeline String.duplicate("c", 64)

  defmodule SuccessfulHandler do
    def run(%Permit{action: :test}) do
      {:ok, %{evidence_digest: String.duplicate("d", 64)}}
    end
  end

  defmodule RaisingHandler do
    def run(%Permit{}), do: raise("bounded handler failed")
  end

  test "the domain exposes one typed authority resource" do
    assert Ash.Domain.Info.resources(Domain) == [Permit]
  end

  test "an operator admits one deterministic permit for an in-progress governed task" do
    task = in_progress_task("admit")
    operator = actor_with_role("operator-admit", :operator)

    attrs = permit_attrs(task)

    assert {:ok, permit} =
             as_actor(operator, fn -> Authz.create(Permit, attrs, action: :admit) end)

    assert permit.state == :admitted
    assert permit.action == :test
    assert permit.permit_id == Permit.deterministic_id(attrs)

    assert {:error, duplicate} =
             as_actor(operator, fn -> Authz.create(Permit, attrs, action: :admit) end)

    assert Exception.message(duplicate) =~ "already"
  end

  test "admission refuses ungoverned tasks, malformed source identity, and wrong roles" do
    inbox_task = task("refuse")
    operator = actor_with_role("operator-refuse", :operator)
    executor = actor_with_role("executor-refuse", :derivation_executor)

    assert {:error, error} =
             as_actor(operator, fn ->
               Authz.create(Permit, permit_attrs(inbox_task), action: :admit)
             end)

    assert Exception.message(error) =~ "in_progress"

    attrs = permit_attrs(in_progress_task("malformed"))

    assert {:error, error} =
             as_actor(operator, fn ->
               Authz.create(Permit, %{attrs | commit_sha: "main"}, action: :admit)
             end)

    assert Exception.message(error) =~ "commit_sha"

    assert {:error, _} =
             as_actor(executor, fn -> Authz.create(Permit, attrs, action: :admit) end)
  end

  test "only a derivation executor may claim and record a typed terminal outcome" do
    task = in_progress_task("outcome")
    operator = actor_with_role("operator-outcome", :operator)
    executor = actor_with_role("executor-outcome", :derivation_executor)
    attrs = permit_attrs(task)

    {:ok, permit} = as_actor(operator, fn -> Authz.create(Permit, attrs, action: :admit) end)

    assert {:error, _} =
             as_actor(operator, fn ->
               Authz.update(permit, %{executor_id: "bounded-executor-v1"}, action: :claim)
             end)

    assert {:error, error} =
             as_actor(executor, fn ->
               Authz.update(permit, %{evidence_digest: @pipeline}, action: :succeed)
             end)

    assert Exception.message(error) =~ "claimed"

    assert {:ok, claimed} =
             as_actor(executor, fn ->
               Authz.update(permit, %{executor_id: "bounded-executor-v1"}, action: :claim)
             end)

    assert claimed.state == :claimed

    assert {:ok, succeeded} =
             as_actor(executor, fn ->
               Authz.update(claimed, %{evidence_digest: @pipeline}, action: :succeed)
             end)

    assert succeeded.state == :succeeded
    assert succeeded.evidence_digest == @pipeline

    assert {:error, _} =
             as_actor(executor, fn ->
               Authz.update(succeeded, %{failure_reason: "late rewrite"}, action: :fail)
             end)
  end

  test "the bounded Oban executor accepts only a permit id and records a typed outcome" do
    task = in_progress_task("bounded-executor")
    operator = actor_with_role("operator-bounded-executor", :operator)
    executor = actor_with_role("executor-bounded-executor", :derivation_executor)

    on_exit(fn ->
      Application.delete_env(:spruce_goose, :derivation_executor_actor)
      Application.delete_env(:spruce_goose, :derivation_handlers)
    end)

    Application.put_env(:spruce_goose, :derivation_executor_actor, executor.name)
    Application.put_env(:spruce_goose, :derivation_handlers, %{test: SuccessfulHandler})

    {:ok, permit} =
      as_actor(operator, fn -> Authz.create(Permit, permit_attrs(task), action: :admit) end)

    assert :ok = Executor.perform(%Oban.Job{args: %{"permit_id" => permit.permit_id}})

    assert {:ok, completed} =
             as_actor(executor, fn -> Authz.read_one(Permit, permit_id: permit.permit_id) end)

    assert completed.state == :succeeded
    assert completed.executor_id == executor.name
    assert completed.evidence_digest == String.duplicate("d", 64)

    assert {:discard, "expected exactly one permit_id"} =
             Executor.perform(%Oban.Job{
               args: %{"permit_id" => permit.permit_id, "command" => "mix test"}
             })
  end

  test "the bounded executor fails closed when an action has no configured handler" do
    task = in_progress_task("missing-handler")
    operator = actor_with_role("operator-missing-handler", :operator)
    executor = actor_with_role("executor-missing-handler", :derivation_executor)

    on_exit(fn ->
      Application.delete_env(:spruce_goose, :derivation_executor_actor)
      Application.delete_env(:spruce_goose, :derivation_handlers)
    end)

    Application.put_env(:spruce_goose, :derivation_executor_actor, executor.name)
    Application.put_env(:spruce_goose, :derivation_handlers, %{})

    {:ok, permit} =
      as_actor(operator, fn -> Authz.create(Permit, permit_attrs(task), action: :admit) end)

    assert {:discard, "no handler configured for test"} =
             Executor.perform(%Oban.Job{args: %{"permit_id" => permit.permit_id}})

    assert {:ok, failed} =
             as_actor(executor, fn -> Authz.read_one(Permit, permit_id: permit.permit_id) end)

    assert failed.state == :failed
    assert failed.failure_reason == "no handler configured for test"
  end

  test "the bounded executor refuses an unconfigured actor without claiming the permit" do
    task = in_progress_task("missing-executor")
    operator = actor_with_role("operator-missing-executor", :operator)

    on_exit(fn -> Application.delete_env(:spruce_goose, :derivation_executor_actor) end)
    Application.delete_env(:spruce_goose, :derivation_executor_actor)

    {:ok, permit} =
      as_actor(operator, fn -> Authz.create(Permit, permit_attrs(task), action: :admit) end)

    assert {:discard, "derivation executor actor is not configured"} =
             Executor.perform(%Oban.Job{args: %{"permit_id" => permit.permit_id}})

    assert Ash.get!(Permit, permit.id, authorize?: false).state == :admitted
  end

  test "a handler exception becomes a typed failed outcome" do
    task = in_progress_task("handler-exception")
    operator = actor_with_role("operator-handler-exception", :operator)
    executor = actor_with_role("executor-handler-exception", :derivation_executor)

    on_exit(fn ->
      Application.delete_env(:spruce_goose, :derivation_executor_actor)
      Application.delete_env(:spruce_goose, :derivation_handlers)
    end)

    Application.put_env(:spruce_goose, :derivation_executor_actor, executor.name)
    Application.put_env(:spruce_goose, :derivation_handlers, %{test: RaisingHandler})

    {:ok, permit} =
      as_actor(operator, fn -> Authz.create(Permit, permit_attrs(task), action: :admit) end)

    assert {:discard, "bounded handler failed"} =
             Executor.perform(%Oban.Job{args: %{"permit_id" => permit.permit_id}})

    failed = Ash.get!(Permit, permit.id, authorize?: false)
    assert failed.state == :failed
    assert failed.failure_reason == "bounded handler failed"
  end

  defp permit_attrs(task) do
    %{
      task_id: task.id,
      source_event_id: "forgejo:1:12:delivery-#{task.task_id}",
      forge_instance: "mama-forgejo",
      repository: "root/sprucegoose",
      commit_sha: @commit,
      tree_sha: @tree,
      ref: "refs/heads/main",
      pipeline_digest: @pipeline,
      action: :test
    }
  end

  defp actor_with_role(name, role) do
    actor =
      Ash.create!(Actor, %{name: name, kind: :agent, created_by: "test"}, authorize?: false)

    Ash.create!(Grant, %{actor_id: actor.id, role: role, scope: "*", granted_by: "test"},
      authorize?: false
    )

    actor
  end

  defp as_actor(actor, fun), do: Authz.with_actor(actor, fun)

  defp in_progress_task(suffix) do
    Enum.reduce([:proposed, :queued, :ready, :in_progress], task(suffix), fn state, current ->
      Ash.update!(current, %{to_state: state}, action: :transition)
    end)
  end

  defp task(suffix) do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "derive-#{suffix}", kind: :oban}]})
    project = Ash.create!(Project, %{key: "derive-#{suffix}", name: "Derive #{suffix}"})

    roadmap =
      Ash.create!(Roadmap, %{
        project_id: project.id,
        key: "derive-#{suffix}",
        name: "Derive #{suffix}"
      })

    workflow =
      Ash.create!(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "derive-#{suffix}",
        name: "Derive #{suffix}",
        definition: definition
      })

    Ash.create!(Task, %{
      workflow_id: workflow.id,
      task_id: SpruceGoose.TaskId.generate(),
      title: "Derive #{suffix}",
      definition_of_done: "typed derivation reaches a terminal outcome",
      runner: :oban
    })
  end
end
