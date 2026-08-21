defmodule SpruceGoose.BlueprintRevisionTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Actors.{Actor, Grant}
  alias SpruceGoose.Authz
  alias SpruceGoose.Workflows.{BlueprintRevision, Project}

  @commit String.duplicate("a", 40)
  @tree String.duplicate("b", 40)
  @digest String.duplicate("c", 64)

  test "an approver registers one immutable exact-source blueprint revision" do
    project = Ash.create!(Project, %{key: "legible", name: "Legible"})
    approver = actor_with_role("blueprint-approver", :approver)
    attrs = attrs(project)

    assert {:ok, revision} =
             Authz.with_actor(approver, fn ->
               Authz.create(BlueprintRevision, attrs, action: :register)
             end)

    assert revision.revision_id == BlueprintRevision.deterministic_id(attrs)
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

  defp attrs(project) do
    %{
      project_id: project.id,
      repository: "root/legible",
      source_commit: @commit,
      source_tree: @tree,
      source_path: ".sprucegoose/project.yaml",
      manifest_digest: @digest,
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
end
