defmodule SpruceGoose.BlueprintRevisionTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Actors.{Actor, Grant}
  alias SpruceGoose.Authz
  alias SpruceGoose.Workflows.{BlueprintRevision, Project, Roadmap, Workflow}

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
                    depends_on: []
                    input: {}
                  - id: build
                    kind: oban
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
end
