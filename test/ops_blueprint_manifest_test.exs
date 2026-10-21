defmodule SpruceGoose.OpsBlueprintManifestTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Blueprints.Applier

  @manifest Path.expand("../.sprucegoose/ops.yaml", __DIR__)

  # {roadmap, workflow, [definition]} — the standing templates for work that
  # belongs to no delivery project.
  @templates [
    {"admin", "admin-routine", ~w(adhoc)},
    {"maintenance", "maintenance-routine", ~w(adhoc dependency-audit)},
    {"support", "support-routine", ~w(adhoc inbox-triage)}
  ]

  setup_all do
    bytes = File.read!(@manifest)
    {:ok, bytes: bytes, manifest: YamlElixir.read_from_string!(bytes)}
  end

  test "binds the standing ops project", %{bytes: bytes} do
    assert {:ok, %{key: "ops", name: "Operations"}} = Applier.project(bytes)
  end

  test "declares exactly the expected roadmaps and workflows", %{manifest: manifest} do
    shape =
      for roadmap <- manifest["roadmaps"], workflow <- roadmap["workflows"] do
        {roadmap["key"], workflow["id"], Enum.map(workflow["definition"]["tasks"], & &1["id"])}
      end

    assert shape == @templates
  end

  # `Applier.task_definition/4` resolves a workflow by id across all roadmaps,
  # so a repeated id would make instantiation silently pick the first.
  test "workflow ids are unique across roadmaps" do
    ids = Enum.map(@templates, &elem(&1, 1))
    assert ids == Enum.uniq(ids)
  end

  test "every template is admissible and independently instantiable", %{bytes: bytes} do
    for {_roadmap, workflow, definitions} <- @templates, key <- definitions do
      assert {:ok, definition} = Applier.task_definition("ops", workflow, key, bytes)
      assert definition.depends_on == [], "#{workflow}/#{key} must not depend on another template"
    end
  end
end
