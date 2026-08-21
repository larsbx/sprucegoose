defmodule SpruceGoose.BlueprintRevisionTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Actors.{Actor, Grant}
  alias SpruceGoose.Authz
  alias SpruceGoose.Workflows.{BlueprintRevision, Project, Roadmap, Task, Workflow}

  @commit String.duplicate("a", 40)
  @tree String.duplicate("b", 40)
  @digest String.duplicate("c", 64)

  setup do
    previous = Application.get_env(:spruce_goose, :blueprint_source_verifier)
    Application.put_env(:spruce_goose, :blueprint_source_verifier, __MODULE__.Verifier)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spruce_goose, :blueprint_source_verifier, previous),
        else: Application.delete_env(:spruce_goose, :blueprint_source_verifier)
    end)
  end

  test "an approver registers one immutable exact-source blueprint revision" do
    project = Ash.create!(Project, %{key: "legible", name: "Legible"})
    approver = actor_with_role("blueprint-approver", :approver)
    attrs = attrs(project)

    assert {:ok, revision} =
             Authz.with_actor(approver, fn ->
               Authz.create(BlueprintRevision, attrs, action: :register)
             end)

    expected = Map.merge(attrs, %{source_tree: @tree, manifest_digest: @digest})
    assert revision.revision_id == BlueprintRevision.deterministic_id(expected)
    assert revision.project_id == project.id
    assert revision.source_commit == @commit
    assert Ash.Resource.Info.action(BlueprintRevision, :update) == nil
    assert Ash.Resource.Info.action(BlueprintRevision, :destroy) == nil

    assert {:error, duplicate} =
             Authz.with_actor(approver, fn ->
               Authz.create(BlueprintRevision, attrs, action: :register)
             end)

    assert Exception.message(duplicate) =~ "already"
  end

  test "registration refuses malformed source identity and non-approvers" do
    project = Ash.create!(Project, %{key: "refuse-blueprint", name: "Refuse"})
    approver = actor_with_role("blueprint-valid", :approver)
    author = actor_with_role("blueprint-author-only", :author)
    attrs = attrs(project)

    assert {:error, error} =
             Authz.with_actor(approver, fn ->
               Authz.create(BlueprintRevision, %{attrs | source_commit: "main"},
                 action: :register
               )
             end)

    assert Exception.message(error) =~ "source_commit"

    assert {:error, _} =
             Authz.with_actor(author, fn ->
               Authz.create(BlueprintRevision, attrs, action: :register)
             end)
  end

  test "apply materializes a complete typed hierarchy in one transaction" do
    project = Ash.create!(Project, %{key: "legible", name: "Legible"})
    approver = actor_with_role("blueprint-applier", :approver)

    assert {:ok, revision} =
             Authz.with_actor(approver, fn ->
               Authz.create(BlueprintRevision, attrs(project), action: :apply)
             end)

    [roadmap] = Ash.read!(Ash.Query.filter_input(Roadmap, project_id: project.id))
    [workflow] = Ash.read!(Ash.Query.filter_input(Workflow, roadmap_id: roadmap.id))
    assert roadmap.project_id == project.id
    assert {roadmap.key, roadmap.name} == {"delivery", "Delivery"}
    assert workflow.roadmap_id == roadmap.id
    assert {workflow.workflow_id, workflow.name} == {"release-v1", "Release v1"}
    assert Enum.map(workflow.definition.tasks, & &1.id) == ["test", "build"]
    assert revision.schema_version == 1
  end

  test "new task admission binds an exact blueprint task definition" do
    project = Ash.create!(Project, %{key: "legible", name: "Legible"})
    approver = actor_with_role("blueprint-task-approver", :approver)
    operator = actor_with_role("blueprint-task-operator", :operator)

    revision =
      Authz.with_actor(approver, fn ->
        {:ok, revision} = Authz.create(BlueprintRevision, attrs(project), action: :apply)
        revision
      end)

    [workflow] = Ash.read!(Ash.Query.filter_input(Workflow, workflow_id: "release-v1"))

    {:ok, mutable_definition} =
      SpruceGoose.Workflows.Definition.parse(%{
        schema_version: 1,
        tasks: [
          %{
            id: "test",
            kind: :oban,
            title: "Mutable projection title",
            definition_of_done: "Mutable projection DoD",
            depends_on: [],
            input: %{}
          }
        ]
      })

    assert {:ok, _} =
             Authz.with_actor(approver, fn ->
               Authz.update(workflow, %{definition: mutable_definition}, action: :revise)
             end)

    assert {:ok, task} =
             Authz.with_actor(operator, fn ->
               Authz.create(
                 Task,
                 %{
                   workflow_id: workflow.id,
                   task_id: "tsk-20260821T170000Z-00000001",
                   task_type: :task,
                   blueprint_revision_id: revision.id,
                   definition_key: "test",
                   priority: 1
                 },
                 action: :instantiate
               )
             end)

    assert task.blueprint_revision_id == revision.id
    assert task.definition_key == "test"
    assert task.title == "Run tests"
    assert task.definition_of_done == "The governed test suite passes"
    assert task.runner == :oban
    assert task.input == %{}
    assert task.artifact_requirements == ["test-report"]

    assert {:error, error} =
             Authz.with_actor(operator, fn ->
               Authz.create(
                 Task,
                 %{
                   workflow_id: workflow.id,
                   task_id: "tsk-20260821T170000Z-00000002",
                   task_type: :task,
                   blueprint_revision_id: revision.id,
                   definition_key: "missing",
                   priority: 1
                 },
                 action: :instantiate
               )
             end)

    assert Exception.message(error) =~ "definition_key"
  end

  test "unbound Ash task creation is unavailable outside an isolated store" do
    project = Ash.create!(Project, %{key: "legible", name: "Bound only"})
    approver = actor_with_role("bound-only-approver", :approver)
    operator = actor_with_role("bound-only-operator", :operator)

    Authz.with_actor(approver, fn ->
      {:ok, _revision} = Authz.create(BlueprintRevision, attrs(project), action: :apply)
    end)

    [workflow] = Ash.read!(Ash.Query.filter_input(Workflow, workflow_id: "release-v1"))
    previous = Application.get_env(:spruce_goose, :allow_unbound_task_admission)
    Application.put_env(:spruce_goose, :allow_unbound_task_admission, false)

    on_exit(fn ->
      Application.put_env(:spruce_goose, :allow_unbound_task_admission, previous)
    end)

    assert {:error, error} =
             Authz.with_actor(operator, fn ->
               Authz.create(Task, %{
                 workflow_id: workflow.id,
                 task_id: "tsk-20260821T170000Z-00000003",
                 task_type: :task,
                 title: "Unbound",
                 definition_of_done: "Must be refused",
                 priority: 1,
                 runner: :oban
               })
             end)

    assert Exception.message(error) =~ "unbound admission is unavailable"
    assert Exception.message(error) =~ "task instantiate"
  end

  test "apply refuses an invalid package without creating partial hierarchy or receipt" do
    Application.put_env(:spruce_goose, :blueprint_source_verifier, __MODULE__.InvalidVerifier)
    project = Ash.create!(Project, %{key: "legible", name: "Legible"})
    approver = actor_with_role("blueprint-invalid", :approver)

    assert {:error, error} =
             Authz.with_actor(approver, fn ->
               Authz.create(BlueprintRevision, attrs(project), action: :apply)
             end)

    assert Exception.message(error) =~ "depends on unknown task"
    assert Ash.read!(Ash.Query.filter_input(Roadmap, project_id: project.id)) == []
    assert Ash.read!(BlueprintRevision) == []
  end

  test "apply refuses invalid artifact requirements before materializing hierarchy" do
    Application.put_env(
      :spruce_goose,
      :blueprint_source_verifier,
      __MODULE__.InvalidArtifactsVerifier
    )

    project = Ash.create!(Project, %{key: "legible", name: "Legible"})
    approver = actor_with_role("blueprint-invalid-artifacts", :approver)

    assert {:error, error} =
             Authz.with_actor(approver, fn ->
               Authz.create(BlueprintRevision, attrs(project), action: :apply)
             end)

    assert Exception.message(error) =~ "must be unique bounded names"
    assert Ash.read!(Ash.Query.filter_input(Roadmap, project_id: project.id)) == []
    assert Ash.read!(BlueprintRevision) == []
  end

  defp attrs(project) do
    %{
      project_id: project.id,
      repository: "root/legible",
      source_commit: @commit,
      source_path: ".sprucegoose/project.yaml",
      schema_version: 1
    }
  end

  defp actor_with_role(name, role) do
    actor = Ash.create!(Actor, %{name: name, kind: :agent, created_by: "test"}, authorize?: false)

    Ash.create!(Grant, %{actor_id: actor.id, role: role, scope: "*", granted_by: "test"},
      authorize?: false
    )

    actor
  end

  defmodule Verifier do
    @behaviour SpruceGoose.Blueprints.SourceVerifier

    @impl true
    def verify(_repository, _commit, _path) do
      bytes = """
      schema_version: 1
      project: legible
      roadmaps:
        - key: delivery
          name: Delivery
          workflows:
            - id: release-v1
              name: Release v1
              definition:
                schema_version: 1
                tasks:
                  - id: test
                    kind: oban
                    title: Run tests
                    definition_of_done: The governed test suite passes
                    depends_on: []
                    artifact_requirements: [test-report]
                    input: {}
                  - id: build
                    kind: oban
                    title: Build release
                    definition_of_done: A reproducible release is built
                    depends_on: [test]
                    input: {}
      """

      {:ok, %{tree: String.duplicate("b", 40), digest: String.duplicate("c", 64), bytes: bytes}}
    end
  end

  defmodule InvalidVerifier do
    @behaviour SpruceGoose.Blueprints.SourceVerifier

    @impl true
    def verify(_repository, _commit, _path) do
      bytes = """
      schema_version: 1
      project: legible
      roadmaps:
        - key: delivery
          name: Delivery
          workflows:
            - id: release-v1
              name: Release v1
              definition:
                schema_version: 1
                tasks:
                  - id: build
                    kind: oban
                    depends_on: [missing]
                    input: {}
      """

      {:ok, %{tree: String.duplicate("b", 40), digest: String.duplicate("c", 64), bytes: bytes}}
    end
  end

  defmodule InvalidArtifactsVerifier do
    @behaviour SpruceGoose.Blueprints.SourceVerifier

    @impl true
    def verify(_repository, _commit, _path) do
      bytes = """
      schema_version: 1
      project: legible
      roadmaps:
        - key: delivery
          name: Delivery
          workflows:
            - id: release-v1
              name: Release v1
              definition:
                schema_version: 1
                tasks:
                  - id: test
                    kind: oban
                    title: Run tests
                    definition_of_done: The governed test suite passes
                    artifact_requirements: [test-report, test-report]
                    depends_on: []
                    input: {}
      """

      {:ok, %{tree: String.duplicate("b", 40), digest: String.duplicate("c", 64), bytes: bytes}}
    end
  end
end
