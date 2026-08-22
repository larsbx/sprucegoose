defmodule SpruceGoose.ConstitutiveMutationLockdownTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Authz
  alias SpruceGoose.Actors.Actor
  alias SpruceGoose.CLI.Command
  alias SpruceGoose.Workflows.{Project, Roadmap, Workflow}

  @legacy_commands [
    ["project", "add", "legacy", "Legacy"],
    ["project", "rename", "legacy", "Renamed"],
    ["project", "remove", "legacy"],
    ["roadmap", "add", "legacy", "roadmap", "Roadmap"],
    ["roadmap", "rename", "legacy", "roadmap", "Renamed"],
    ["roadmap", "remove", "legacy", "roadmap"],
    ["workflow", "add", "--project", "legacy", "--roadmap", "roadmap"],
    ["workflow", "rename", "legacy", "roadmap", "flow", "Renamed"],
    ["workflow", "remove", "legacy", "roadmap", "flow"]
  ]

  test "the supported CLI refuses direct constitutive mutations" do
    for argv <- @legacy_commands do
      assert {:error, message} = Command.parse(argv)
      assert message =~ "verified repository blueprint"
    end

    help = Command.help()
    refute Enum.any?(help.commands["project"], &String.starts_with?(&1, "add "))
    refute Enum.any?(help.commands["roadmap"], &String.starts_with?(&1, "add "))
    refute Enum.any?(help.commands["workflow"], &String.starts_with?(&1, "add "))
  end

  test "legacy Ash mutations fail closed when production compatibility is disabled" do
    previous = Application.get_env(:spruce_goose, :allow_legacy_hierarchy_mutation)
    Application.put_env(:spruce_goose, :allow_legacy_hierarchy_mutation, false)

    on_exit(fn ->
      Application.put_env(:spruce_goose, :allow_legacy_hierarchy_mutation, previous)
    end)

    actor = Ash.read_one!(Ash.Query.filter_input(Actor, name: "test-system"), authorize?: false)

    assert {:error, error} =
             Authz.with_actor(actor, fn ->
               Authz.create(Project, %{key: "blocked", name: "Blocked"})
             end)

    assert Exception.message(error) =~ "verified repository blueprint"

    assert legacy_action_names(Project) == [:create, :destroy, :rename]
    assert legacy_action_names(Roadmap) == [:create, :destroy, :rename, :revise]

    assert legacy_action_names(Workflow) == [
             :create,
             :destroy,
             :rename,
             :replace_definition,
             :revise
           ]
  end

  defp legacy_action_names(resource) do
    resource
    |> Ash.Resource.Info.actions()
    |> Enum.filter(&(&1.name not in [:read, :apply_blueprint, :apply_blueprint_revision]))
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end
end
