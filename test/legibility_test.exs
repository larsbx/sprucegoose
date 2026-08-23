defmodule SpruceGoose.LegibilityTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Actors.{Actor, Grant}
  alias SpruceGoose.Authz
  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Legibility
  alias SpruceGoose.Workflows.{Definition, Project, Roadmap, Task, Workflow}

  test "project view renders stable read-only machine, Markdown, and DOT projections" do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "view", kind: :oban}]})
    project = Ash.create!(Project, %{key: "legibility-view", name: "Legibility View"})

    roadmap =
      Ash.create!(Roadmap, %{project_id: project.id, key: "delivery", name: "Delivery"})

    workflow =
      Ash.create!(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "delivery-v1",
        name: "Delivery v1",
        definition: definition
      })

    task =
      Ash.create!(Task, %{
        workflow_id: workflow.id,
        task_id: SpruceGoose.TaskId.generate(),
        title: "Visible task",
        definition_of_done: "The task is legible",
        priority: 3,
        runner: :oban
      })

    assert {:ok, view} = Executor.run({:view_project, "legibility-view"})
    assert view.snapshot.project.key == "legibility-view"

    assert get_in(view.snapshot, [:roadmaps, Access.at(0), :workflows, Access.at(0), :tasks]) == [
             %{
               id: task.task_id,
               title: "Visible task",
               type: :task,
               state: :inbox,
               priority: 3,
               definition_of_done: "The task is legible"
             }
           ]

    assert view.markdown =~ "Generated read-only from SpruceGoose/Ash authority"
    assert view.markdown =~ task.task_id
    assert view.dot =~ ~s("#{task.task_id}")
  end

  test "materialize writes a byte-identical archive tree on rebuild" do
    task = seed_project("legibility-archive", "Legibility Archive")
    root = Path.join(System.tmp_dir!(), "legible-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    operator = actor_with_role("legibility-archive-operator", :operator)

    assert {:ok, result} =
             Authz.with_actor(operator, fn ->
               Legibility.materialize(["legibility-archive"], root)
             end)

    assert result.root == root
    assert [%{project: "legibility-archive", files: files}] = result.projects
    assert Enum.sort(files) == ["README.md", "graph.dot", "snapshot.json"]

    directory = Path.join([root, "projects", "legibility-archive"])
    assert File.read!(Path.join(root, "README.md")) =~ "Do not edit this tree as"
    assert File.read!(Path.join(directory, "README.md")) =~ task.task_id
    assert File.read!(Path.join(directory, "graph.dot")) =~ ~s("#{task.task_id}")

    decoded = directory |> Path.join("snapshot.json") |> File.read!() |> Jason.decode!()
    assert decoded["project"]["key"] == "legibility-archive"

    # Drift must be a real authority change or a generator bug, never a merge:
    # rebuilding unchanged authority has to reproduce every byte.
    first = digest_tree(root)

    assert {:ok, _} =
             Authz.with_actor(operator, fn ->
               Legibility.materialize(["legibility-archive"], root)
             end)

    assert digest_tree(root) == first
  end

  test "materialize refuses an unreadable project and writes no partial tree" do
    seed_project("legibility-unauthorized", "Legibility Unauthorized")
    root = Path.join(System.tmp_dir!(), "legible-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    operator = actor_with_role("legibility-unauthorized-operator", :operator)

    assert {:error, _} =
             Authz.with_actor(operator, fn ->
               Legibility.materialize(["legibility-missing"], root)
             end)

    refute File.exists?(Path.join([root, "projects", "legibility-missing"]))
  end

  defp seed_project(key, name) do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "view", kind: :oban}]})
    project = Ash.create!(Project, %{key: key, name: name})
    roadmap = Ash.create!(Roadmap, %{project_id: project.id, key: "delivery", name: "Delivery"})

    workflow =
      Ash.create!(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "delivery-v1",
        name: "Delivery v1",
        definition: definition
      })

    Ash.create!(Task, %{
      workflow_id: workflow.id,
      task_id: SpruceGoose.TaskId.generate(),
      title: "Archived task",
      definition_of_done: "The task is archived",
      priority: 3,
      runner: :oban
    })
  end

  defp actor_with_role(name, role) do
    actor = Ash.create!(Actor, %{name: name, kind: :agent, created_by: "test"}, authorize?: false)

    Ash.create!(Grant, %{actor_id: actor.id, role: role, scope: "*", granted_by: "test"},
      authorize?: false
    )

    actor
  end

  defp digest_tree(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Enum.map(fn path ->
      {Path.relative_to(path, root), :crypto.hash(:sha256, File.read!(path))}
    end)
  end
end
