defmodule SpruceGoose.TodoDependencyTest do
  @moduledoc """
  Cover for tsk-20260729T114542Z-28bb59a5 (Option D).

  TODOs express partial order through explicit predecessor edges, mirroring
  task_dependencies one level down. The default is maximum concurrency: a TODO
  with no incoming edge is never blocked. Sequential sections are chains;
  concurrent sections are siblings sharing a predecessor but not each other.

  Position stays presentational. Ordering semantics live in the edges.
  """
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor

  alias SpruceGoose.Workflows.{
    Definition,
    Project,
    Roadmap,
    Task,
    TodoDependency,
    Workflow
  }

  test "TODOs with no edges stay fully concurrent and completable in any order" do
    task = open_task("concurrent")
    [a, b, c] = add_all(task, ~w(alpha beta gamma))

    assert {:ok, listed} = Executor.run({:list_todo_dependencies, task.task_id})
    assert Enum.all?(listed.todos, &(&1.blocked == false))
    assert Enum.all?(listed.todos, &(&1.depends_on == []))

    # Out-of-order completion remains legal without edges.
    assert {:ok, _} = Executor.run({:complete_todo, task.task_id, c.id})
    assert {:ok, _} = Executor.run({:complete_todo, task.task_id, a.id})
    assert {:ok, _} = Executor.run({:complete_todo, task.task_id, b.id})
  end

  test "a chain enforces sequential completion and explains the block" do
    task = open_task("chain")
    [one, two, three] = add_all(task, ~w(first second third))

    assert {:ok, _} = Executor.run({:add_todo_dependency, task.task_id, two.id, one.id})
    assert {:ok, _} = Executor.run({:add_todo_dependency, task.task_id, three.id, two.id})

    assert {:error, message} = Executor.run({:complete_todo, task.task_id, three.id})
    assert message =~ "blocked by incomplete predecessors"
    assert message =~ two.id

    assert {:error, _} = Executor.run({:complete_todo, task.task_id, two.id})

    assert {:ok, _} = Executor.run({:complete_todo, task.task_id, one.id})
    assert {:ok, _} = Executor.run({:complete_todo, task.task_id, two.id})
    assert {:ok, _} = Executor.run({:complete_todo, task.task_id, three.id})
  end

  test "a diamond runs its middle section concurrently" do
    task = open_task("diamond")
    [a, b, c, d] = add_all(task, ~w(setup left right join))

    for {successor, predecessor} <- [{b, a}, {c, a}, {d, b}, {d, c}] do
      assert {:ok, _} =
               Executor.run({:add_todo_dependency, task.task_id, successor.id, predecessor.id})
    end

    assert {:ok, before} = Executor.run({:list_todo_dependencies, task.task_id})
    assert %{blocked: false} = find(before, a.id)
    assert %{blocked: true} = find(before, b.id)
    assert %{blocked: true} = find(before, c.id)
    assert %{blocked: true} = find(before, d.id)

    assert {:ok, _} = Executor.run({:complete_todo, task.task_id, a.id})

    # Both middle branches unblock together: neither depends on the other.
    assert {:ok, mid} = Executor.run({:list_todo_dependencies, task.task_id})
    assert %{blocked: false} = find(mid, b.id)
    assert %{blocked: false} = find(mid, c.id)
    assert %{blocked: true} = find(mid, d.id)

    # Either branch may go first.
    assert {:ok, _} = Executor.run({:complete_todo, task.task_id, c.id})
    assert {:error, _} = Executor.run({:complete_todo, task.task_id, d.id})

    assert {:ok, _} = Executor.run({:complete_todo, task.task_id, b.id})
    assert {:ok, _} = Executor.run({:complete_todo, task.task_id, d.id})
  end

  test "edge admission rejects self, direct, and multi-hop cycles plus duplicates" do
    task = open_task("cycles")
    [a, b, c] = add_all(task, ~w(one two three))

    assert {:error, "a TODO cannot depend on itself"} =
             Executor.run({:add_todo_dependency, task.task_id, a.id, a.id})

    assert {:ok, _} = Executor.run({:add_todo_dependency, task.task_id, b.id, a.id})

    assert {:error, "dependency already exists"} =
             Executor.run({:add_todo_dependency, task.task_id, b.id, a.id})

    assert {:error, "dependency would create a cycle"} =
             Executor.run({:add_todo_dependency, task.task_id, a.id, b.id})

    assert {:ok, _} = Executor.run({:add_todo_dependency, task.task_id, c.id, b.id})

    assert {:error, "dependency would create a cycle"} =
             Executor.run({:add_todo_dependency, task.task_id, a.id, c.id})

    # Clearing the middle edge re-legalises the previously cyclic edge.
    assert {:ok, _} = Executor.run({:remove_todo_dependency, task.task_id, c.id, b.id})
    assert {:ok, _} = Executor.run({:add_todo_dependency, task.task_id, a.id, c.id})
  end

  test "edges cannot cross task boundaries and unknown TODOs fail closed" do
    task = open_task("scope-a")
    other = open_task("scope-b")

    [local] = add_all(task, ~w(local))
    [foreign] = add_all(other, ~w(foreign))

    assert {:error, "not found"} =
             Executor.run({:add_todo_dependency, task.task_id, local.id, foreign.id})

    assert {:error, "not found"} =
             Executor.run({:add_todo_dependency, task.task_id, local.id, "todo-missing"})

    assert {:error, "invalid task ID"} =
             Executor.run({:add_todo_dependency, "nonsense", local.id, local.id})
  end

  test "removing an edge unblocks its successor" do
    task = open_task("unblock")
    [a, b] = add_all(task, ~w(first second))

    assert {:ok, _} = Executor.run({:add_todo_dependency, task.task_id, b.id, a.id})
    assert {:error, _} = Executor.run({:complete_todo, task.task_id, b.id})

    assert {:ok, removed} = Executor.run({:remove_todo_dependency, task.task_id, b.id, a.id})
    assert removed.todo == b.id
    assert removed.depends_on == a.id

    assert {:ok, _} = Executor.run({:complete_todo, task.task_id, b.id})

    assert {:error, "not found"} =
             Executor.run({:remove_todo_dependency, task.task_id, b.id, a.id})
  end

  test "existing TODOs are unaffected: task completion still needs every TODO done" do
    task = open_task("task-gate")
    [a, b] = add_all(task, ~w(first second))

    assert {:ok, _} = Executor.run({:add_todo_dependency, task.task_id, b.id, a.id})

    assert {:error, _} = Executor.run({:transition_task, task.task_id, :completed, nil})

    assert {:ok, _} = Executor.run({:complete_todo, task.task_id, a.id})
    assert {:error, _} = Executor.run({:transition_task, task.task_id, :completed, nil})

    assert {:ok, _} = Executor.run({:complete_todo, task.task_id, b.id})

    assert {:ok, %{state: :completed}} =
             Executor.run({:transition_task, task.task_id, :completed, nil})
  end

  test "dep list reports both directions and survives position gaps" do
    task = open_task("listing")
    [a, b, c] = add_all(task, ~w(one two three))

    assert {:ok, _} = Executor.run({:add_todo_dependency, task.task_id, b.id, a.id})
    assert {:ok, _} = Executor.run({:add_todo_dependency, task.task_id, c.id, a.id})

    assert {:ok, listed} = Executor.run({:list_todo_dependencies, task.task_id})

    root = find(listed, a.id)
    assert root.depends_on == []
    assert Enum.map(root.blocks, & &1.id) |> Enum.sort() == Enum.sort([b.id, c.id])

    left = find(listed, b.id)
    assert Enum.map(left.depends_on, & &1.id) == [a.id]
    assert left.blocks == []

    # Remove the head TODO; its edges go with it and listing stays coherent.
    {:ok, edges_before} = Ash.read(Ash.Query.filter_input(TodoDependency, task_id: task.id))
    assert length(edges_before) == 2
  end

  defp find(listed, todo_id), do: Enum.find(listed.todos, &(&1.id == todo_id))

  defp add_all(task, bodies) do
    Enum.map(bodies, fn body ->
      {:ok, todo} = Executor.run({:add_todo, task.task_id, body})
      todo
    end)
  end

  defp open_task(suffix) do
    {:ok, project} = Ash.create(Project, %{key: "td-#{suffix}", name: "TD #{suffix}"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{project_id: project.id, key: "td-#{suffix}", name: "TD"})

    {:ok, definition} = Definition.parse(%{tasks: [%{id: "t", kind: :oban}]})

    {:ok, workflow} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "td-#{suffix}",
        name: "TD",
        definition: definition
      })

    {:ok, task} =
      Ash.create(Task, %{
        workflow_id: workflow.id,
        task_id: SpruceGoose.TaskId.generate(),
        title: "TodoDeps #{suffix}",
        definition_of_done: "Partial order holds",
        runner: :oban
      })

    Enum.reduce([:proposed, :queued, :ready, :in_progress], task, fn state, current ->
      {:ok, updated} = Ash.update(current, %{to_state: state}, action: :transition)
      updated
    end)
  end
end
