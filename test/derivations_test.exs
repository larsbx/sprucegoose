defmodule SpruceGoose.DerivationsTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Actors.{Actor, Grant}
  alias SpruceGoose.Authz
  alias SpruceGoose.CLI.Executor, as: CLIExecutor
  alias SpruceGoose.Derivations.{Domain, Executor, Permit}
  alias SpruceGoose.Kernel.Postgres.EventLedger
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

    previous_actor = Application.get_env(:spruce_goose, :derivation_executor_actor)
    previous_handlers = Application.get_env(:spruce_goose, :derivation_handlers)

    on_exit(fn ->
      restore_env(:derivation_executor_actor, previous_actor)
      restore_env(:derivation_handlers, previous_handlers)
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

    assert {:ok, events} = EventLedger.read(EventLedger.new(), "authority:sprucegoose")
    assert Enum.map(events, & &1.payload["command"]) == List.duplicate("derivation_transition", 2)

    assert {:discard, "expected exactly one permit_id"} =
             Executor.perform(%Oban.Job{
               args: %{"permit_id" => permit.permit_id, "command" => "mix test"}
             })
  end

  test "the bounded executor fails closed when an action has no configured handler" do
    task = in_progress_task("missing-handler")
    operator = actor_with_role("operator-missing-handler", :operator)
    executor = actor_with_role("executor-missing-handler", :derivation_executor)

    previous_actor = Application.get_env(:spruce_goose, :derivation_executor_actor)
    previous_handlers = Application.get_env(:spruce_goose, :derivation_handlers)

    on_exit(fn ->
      restore_env(:derivation_executor_actor, previous_actor)
      restore_env(:derivation_handlers, previous_handlers)
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

    previous_actor = Application.get_env(:spruce_goose, :derivation_executor_actor)
    on_exit(fn -> restore_env(:derivation_executor_actor, previous_actor) end)
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

    previous_actor = Application.get_env(:spruce_goose, :derivation_executor_actor)
    previous_handlers = Application.get_env(:spruce_goose, :derivation_handlers)

    on_exit(fn ->
      restore_env(:derivation_executor_actor, previous_actor)
      restore_env(:derivation_handlers, previous_handlers)
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

  test "the fixed verify_artifact handler verifies CAS input and stores deterministic evidence" do
    root = Path.join(System.tmp_dir!(), "sprucegoose-verify-handler-#{System.unique_integer()}")
    previous_root = Application.fetch_env!(:spruce_goose, :artifact_store_root)
    previous_actor = Application.get_env(:spruce_goose, :derivation_executor_actor)
    previous_handlers = Application.get_env(:spruce_goose, :derivation_handlers)
    executor = actor_with_role("executor-fixed-verify", :derivation_executor)

    Application.put_env(:spruce_goose, :artifact_store_root, root)
    Application.put_env(:spruce_goose, :derivation_executor_actor, executor.name)

    Application.put_env(:spruce_goose, :derivation_handlers, %{
      verify_artifact: SpruceGoose.Derivations.VerifyArtifact
    })

    on_exit(fn ->
      Application.put_env(:spruce_goose, :artifact_store_root, previous_root)
      restore_env(:derivation_executor_actor, previous_actor)
      restore_env(:derivation_handlers, previous_handlers)
      File.rm_rf!(root)
    end)

    {:ok, input} = SpruceGoose.Artifacts.Store.put_bytes("artifact bytes")
    task = in_progress_task("fixed-verify")
    operator = actor_with_role("operator-fixed-verify", :operator)

    attrs =
      task
      |> permit_attrs()
      |> Map.merge(%{action: :verify_artifact, input_artifact_digest: input.digest})

    {:ok, permit} = as_actor(operator, fn -> Authz.create(Permit, attrs, action: :admit) end)

    assert {:ok, first} = SpruceGoose.Derivations.VerifyArtifact.run(permit)
    assert {:ok, ^first} = SpruceGoose.Derivations.VerifyArtifact.run(permit)
    assert :ok = Executor.perform(%Oban.Job{args: %{"permit_id" => permit.permit_id}})

    completed = Ash.get!(Permit, permit.id, authorize?: false)
    assert completed.state == :succeeded
    assert completed.artifact_digest == input.digest

    assert {:ok, %{digest: evidence}} =
             SpruceGoose.Artifacts.Store.verify(completed.evidence_digest)

    assert evidence == completed.evidence_digest
  end

  test "verify_artifact admission requires a typed input content id" do
    task = in_progress_task("verify-input")
    operator = actor_with_role("operator-verify-input", :operator)
    attrs = Map.put(permit_attrs(task), :action, :verify_artifact)

    assert {:error, error} =
             as_actor(operator, fn -> Authz.create(Permit, attrs, action: :admit) end)

    assert Exception.message(error) =~ "input_artifact_digest"
  end

  test "PostgreSQL refuses action-input mismatches outside Ash" do
    task = in_progress_task("sql-input-guard")
    operator = actor_with_role("operator-sql-input-guard", :operator)

    {:ok, permit} =
      as_actor(operator, fn -> Authz.create(Permit, permit_attrs(task), action: :admit) end)

    assert {:error, %Postgrex.Error{postgres: %{constraint: "typed_derivation_input"}}} =
             Ecto.Adapters.SQL.query(
               SpruceGoose.Repo,
               "UPDATE derivation_permits SET input_artifact_digest = $1 WHERE id = $2::text::uuid",
               [String.duplicate("e", 64), permit.id],
               mode: :savepoint
             )
  end

  test "the CLI atomically admits and schedules one opaque permit job" do
    task = in_progress_task("cli-admit")
    operator = actor_with_role("operator-cli-admit", :operator)
    attrs = task |> permit_attrs() |> Map.put(:task_id, task.task_id)

    assert {:ok, admitted} = CLIExecutor.run({:admit_derivation, attrs}, operator.name)
    assert admitted.state == :admitted
    assert admitted.action == :test
    assert admitted.task_id == task.task_id

    assert %Oban.Job{args: %{"permit_id" => permit_id}} =
             SpruceGoose.Repo.one!(from(job in Oban.Job, where: job.queue == "derivations"))

    assert permit_id == admitted.permit_id
    assert {:ok, shown} = CLIExecutor.run({:show_derivation, permit_id}, operator.name)
    assert shown == admitted

    assert {:error, _duplicate} = CLIExecutor.run({:admit_derivation, attrs}, operator.name)
    assert SpruceGoose.Repo.aggregate(Oban.Job, :count) == 1
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

  defp restore_env(key, nil), do: Application.delete_env(:spruce_goose, key)
  defp restore_env(key, value), do: Application.put_env(:spruce_goose, key, value)

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
