defmodule SpruceGoose.TodoPositionWedgeTest do
  @moduledoc """
  Regression cover for tsk-20260729T111735Z-43e228b3.

  create_todo/3 assigned `position: length(todos) + 1` while remove_todo
  deleted without renumbering, against a unique index on
  (task_id, position). Any non-tail removal therefore made the next insert
  collide permanently:

      [1,2,3,4,5] remove #2 -> [1,3,4,5], next add targets 5 -> WEDGED
      remove head -> [2,3],   three consecutive adds -> WEDGED, WEDGED, WEDGED

  Tail removal was safe, which is why it survived P1.3 review.

  Position is presentational: nothing enforces working order and
  out-of-order completion is permitted. Ordering semantics belong to
  explicit TODO dependency edges, not to this column. These tests pin
  admission against gaps rather than asserting gap-free numbering.
  """
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor

  alias SpruceGoose.Workflows.{
    Definition,
    Project,
    Roadmap,
    Task,
    Todo,
    Workflow
  }

  test "admission survives removal from the head of the checklist" do
    task = open_task("head")

    todos = add_all(task, ~w(one two three))
    {:ok, _} = Executor.run({:remove_todo, task.task_id, hd(todos).id})

    assert {:ok, added} = Executor.run({:add_todo, task.task_id, "after head removal"})
    assert added.position not in remaining_positions(task, added.id)

    assert {:ok, again} = Executor.run({:add_todo, task.task_id, "and another"})
    assert again.position not in remaining_positions(task, again.id)
  end

  test "admission survives removal from the middle of the checklist" do
    task = open_task("middle")

    todos = add_all(task, ~w(one two three four five))
    {:ok, _} = Executor.run({:remove_todo, task.task_id, Enum.at(todos, 1).id})

    assert {:ok, added} = Executor.run({:add_todo, task.task_id, "after middle removal"})
    assert added.position not in remaining_positions(task, added.id)
  end

  test "admission survives repeated interior removals" do
    task = open_task("repeat")

    todos = add_all(task, ~w(one two three four five six))

    {:ok, _} = Executor.run({:remove_todo, task.task_id, Enum.at(todos, 1).id})
    {:ok, _} = Executor.run({:remove_todo, task.task_id, Enum.at(todos, 2).id})

    for attempt <- 1..3 do
      assert {:ok, added} = Executor.run({:add_todo, task.task_id, "retry #{attempt}"})
      assert added.position not in remaining_positions(task, added.id)
    end
  end

  test "admission still works after tail removal" do
    task = open_task("tail")

    todos = add_all(task, ~w(one two three))
    {:ok, _} = Executor.run({:remove_todo, task.task_id, List.last(todos).id})

    assert {:ok, added} = Executor.run({:add_todo, task.task_id, "after tail removal"})
    assert added.position not in remaining_positions(task, added.id)
  end

  test "positions stay unique and listing stays ordered across churn" do
    task = open_task("churn")

    todos = add_all(task, ~w(a b c d e))
    {:ok, _} = Executor.run({:remove_todo, task.task_id, Enum.at(todos, 0).id})
    {:ok, _} = Executor.run({:remove_todo, task.task_id, Enum.at(todos, 3).id})
    {:ok, _} = Executor.run({:add_todo, task.task_id, "f"})
    {:ok, _} = Executor.run({:add_todo, task.task_id, "g"})

    {:ok, %{todos: listed}} = Executor.run({:list_todos, task.task_id})

    positions = Enum.map(listed, & &1.position)

    assert length(Enum.uniq(positions)) == length(positions)
    assert positions == Enum.sort(positions)
  end

  test "concurrent admission after an interior removal keeps positions unique" do
    task = open_task("concurrent")

    todos = add_all(task, ~w(one two three))
    {:ok, _} = Executor.run({:remove_todo, task.task_id, Enum.at(todos, 1).id})

    results =
      1..8
      |> Elixir.Task.async_stream(
        fn n -> Executor.run({:add_todo, task.task_id, "concurrent #{n}"}) end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1))

    {:ok, stored} = Ash.read(Ash.Query.filter_input(Todo, task_id: task.id))
    positions = Enum.map(stored, & &1.position)

    assert length(Enum.uniq(positions)) == length(positions)
    assert length(stored) == 2 + 8
  end

  defp remaining_positions(task, exclude_todo_id) do
    {:ok, stored} = Ash.read(Ash.Query.filter_input(Todo, task_id: task.id))

    stored
    |> Enum.reject(&(&1.todo_id == exclude_todo_id))
    |> Enum.map(& &1.position)
  end

  defp add_all(task, bodies) do
    Enum.map(bodies, fn body ->
      {:ok, todo} = Executor.run({:add_todo, task.task_id, body})
      todo
    end)
  end

  defp open_task(suffix) do
    {:ok, project} = Ash.create(Project, %{key: "wedge-#{suffix}", name: "Wedge #{suffix}"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{project_id: project.id, key: "wedge-#{suffix}", name: "Wedge"})

    {:ok, definition} = Definition.parse(%{tasks: [%{id: "t", kind: :oban}]})

    {:ok, workflow} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "wedge-#{suffix}",
        name: "Wedge",
        definition: definition
      })

    {:ok, task} =
      Ash.create(Task, %{
        workflow_id: workflow.id,
        task_id: SpruceGoose.TaskId.generate(),
        title: "Wedge #{suffix}",
        definition_of_done: "Admission survives removal",
        runner: :oban
      })

    Enum.reduce([:proposed, :queued, :ready, :in_progress], task, fn state, current ->
      {:ok, updated} = Ash.update(current, %{to_state: state}, action: :transition)
      updated
    end)
  end
end
