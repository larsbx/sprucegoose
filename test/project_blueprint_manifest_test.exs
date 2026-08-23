defmodule SpruceGoose.ProjectBlueprintManifestTest do
  use ExUnit.Case, async: true

  alias SpruceGoose.Workflows.Definition

  @manifest Path.expand("../.sprucegoose/project.yaml", __DIR__)

  test "kernel remediation phases are repository-authored and dependency ordered" do
    manifest = @manifest |> YamlElixir.read_from_file!() |> atomize()
    [roadmap] = manifest.roadmaps
    [workflow] = roadmap.workflows

    assert {:ok, definition} = Definition.parse(workflow.definition)

    tasks = Map.new(definition.tasks, &{&1.id, &1})

    assert tasks["constitutive-mutation-lockdown"].depends_on == ["knowledge-projection"]
    assert tasks["constitutional-vertical-slice"].depends_on == ["authority-contract"]

    assert tasks["certified-event-ledger-shadow"].depends_on == [
             "constitutive-mutation-lockdown",
             "constitutional-vertical-slice"
           ]

    assert tasks["certified-event-shadow-append"].depends_on == [
             "certified-event-ledger-shadow"
           ]

    assert tasks["grandfathered-baseline"].depends_on == ["certified-event-shadow-append"]
    assert tasks["deterministic-replay-parity"].depends_on == ["grandfathered-baseline"]
    assert tasks["projector-event-routing"].depends_on == ["deterministic-replay-parity"]

    assert tasks["postgresql-ga-readiness-diagnosis"].depends_on == [
             "projector-event-routing"
           ]

    assert Enum.sort(tasks["canary-cutover"].depends_on) ==
             Enum.sort(["projector-event-routing", "runtime-capability-transfer"])
  end

  defp atomize(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {String.to_existing_atom(key), atomize(item)} end)
  end

  defp atomize(value) when is_list(value), do: Enum.map(value, &atomize/1)
  defp atomize(value), do: value
end
