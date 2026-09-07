defmodule SpruceGoose.BlueprintApplyScopeTest do
  @moduledoc """
  Evidence for the blueprint-apply blast radius.

  Two questions decide whether applying `.sprucegoose/project.yaml` against a
  live project is safe:

    1. Does apply touch roadmaps the manifest does NOT declare?
       (If it prunes them, applying a drifted manifest is destructive.)
    2. Does apply merge a declared workflow's task definitions, or replace them
       wholesale? (If it replaces, a manifest missing definitions silently
       deletes reviewed specs.)

  Reading `SpruceGoose.Blueprints.Applier` suggests additive-at-roadmap and
  replace-at-definition. These tests assert that behaviour instead of trusting
  the read.
  """
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Actors.{Actor, Grant}
  alias SpruceGoose.Authz
  alias SpruceGoose.Workflows.{BlueprintRevision, Project, Roadmap, Workflow}

  @commit String.duplicate("a", 40)

  setup do
    previous = Application.get_env(:spruce_goose, :blueprint_source_verifier)
    Application.put_env(:spruce_goose, :blueprint_source_verifier, __MODULE__.Verifier)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spruce_goose, :blueprint_source_verifier, previous),
        else: Application.delete_env(:spruce_goose, :blueprint_source_verifier)
    end)
  end

  test "apply leaves roadmaps absent from the manifest untouched" do
    project = Ash.create!(Project, %{key: "legible", name: "Legible"})
    approver = actor_with_role("scope-undeclared-approver", :approver)

    # A roadmap that exists live but is NOT named in the manifest, standing in
    # for the eight openclaw-system roadmaps missing from project.yaml.
    undeclared =
      Ash.create!(Roadmap, %{
        project_id: project.id,
        key: "undeclared-roadmap",
        name: "Undeclared Roadmap"
      })

    undeclared_workflow =
      Ash.create!(Workflow, %{
        roadmap_id: undeclared.id,
        workflow_id: "undeclared-v1",
        name: "Undeclared v1",
        definition: definition(["keep-me"])
      })

    assert {:ok, _revision} =
             Authz.with_actor(approver, fn ->
               Authz.create(BlueprintRevision, attrs(project), action: :apply)
             end)

    reloaded_roadmap = Ash.get!(Roadmap, undeclared.id)
    reloaded_workflow = Ash.get!(Workflow, undeclared_workflow.id)

    assert reloaded_roadmap.key == "undeclared-roadmap"
    assert reloaded_roadmap.name == "Undeclared Roadmap"
    assert Enum.map(reloaded_workflow.definition.tasks, & &1.id) == ["keep-me"]

    # And the manifest's own roadmap was still materialized alongside it.
    keys =
      Roadmap
      |> Ash.Query.filter_input(project_id: project.id)
      |> Ash.read!()
      |> Enum.map(& &1.key)
      |> Enum.sort()

    assert keys == ["delivery", "undeclared-roadmap"]
  end

  test "apply replaces a declared workflow's definitions wholesale rather than merging" do
    project = Ash.create!(Project, %{key: "legible", name: "Legible"})
    approver = actor_with_role("scope-replace-approver", :approver)

    # Materialize the manifest once: delivery/release-v1 with [test, build].
    assert {:ok, _} =
             Authz.with_actor(approver, fn ->
               Authz.create(BlueprintRevision, attrs(project), action: :apply)
             end)

    [workflow] = Ash.read!(Ash.Query.filter_input(Workflow, workflow_id: "release-v1"))
    assert Enum.map(workflow.definition.tasks, & &1.id) == ["test", "build"]

    # Live drift: a definition added after the manifest was last written,
    # exactly like the 11 extra definitions on sprucegoose-convergence-v1.
    assert {:ok, drifted} =
             Authz.with_actor(approver, fn ->
               Authz.update(
                 workflow,
                 %{definition: definition(["test", "build", "added-after-manifest"])},
                 action: :revise
               )
             end)

    assert Enum.map(drifted.definition.tasks, & &1.id) ==
             ["test", "build", "added-after-manifest"]

    # Re-apply the SAME manifest, which never mentions added-after-manifest.
    assert {:ok, _} =
             Authz.with_actor(approver, fn ->
               Authz.create(
                 BlueprintRevision,
                 %{attrs(project) | source_commit: String.duplicate("d", 40)},
                 action: :apply
               )
             end)

    [reapplied] = Ash.read!(Ash.Query.filter_input(Workflow, workflow_id: "release-v1"))
    ids = Enum.map(reapplied.definition.tasks, & &1.id)

    # THE HAZARD: not a merge. The drifted definition is gone.
    refute "added-after-manifest" in ids
    assert ids == ["test", "build"]
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

  defp definition(ids) do
    {:ok, parsed} =
      SpruceGoose.Workflows.Definition.parse(%{
        schema_version: 1,
        tasks:
          Enum.map(ids, fn id ->
            %{
              id: id,
              kind: :oban,
              title: "Title for #{id}",
              definition_of_done: "DoD for #{id}",
              depends_on: [],
              input: %{}
            }
          end)
      })

    parsed
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
    def verify(_repository, commit, _path) do
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
                    input: {}
                  - id: build
                    kind: oban
                    title: Build release
                    definition_of_done: A reproducible release is built
                    depends_on: [test]
                    input: {}
      """

      # Vary the tree/digest with the commit so a second apply is a distinct
      # revision rather than a duplicate-identity refusal.
      seed = String.slice(commit, 0, 1)

      {:ok,
       %{
         tree: String.duplicate(seed, 40),
         digest: String.duplicate(seed, 64),
         bytes: bytes
       }}
    end
  end
end
