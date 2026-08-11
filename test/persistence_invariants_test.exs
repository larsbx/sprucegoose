defmodule SpruceGoose.PersistenceInvariantsTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Workflows.{
    Definition,
    Dependency,
    Project,
    Roadmap,
    Task,
    Todo,
    TodoDependency,
    Workflow
  }

  test "task revisions and transitions reject stale records" do
    {_workflow, task} = hierarchy()
    stale = task

    assert {:ok, revised} = Ash.update(task, %{title: "revised"}, action: :revise)
    assert revised.lock_version == 2
    assert {:error, error} = Ash.update(stale, %{title: "lost update"}, action: :revise)
    assert Exception.message(error) =~ "stale"

    assert {:ok, transitioned} =
             Ash.update(revised, %{to_state: :proposed}, action: :transition)

    assert transitioned.lock_version == 3

    assert {:error, error} =
             Ash.update(revised, %{to_state: :cancelled}, action: :transition)

    assert Exception.message(error) =~ "stale"
  end

  test "workflow definition replacement rejects stale records" do
    {workflow, _task} = hierarchy()
    stale = workflow
    replacement = definition("replacement")

    assert {:ok, updated} =
             Ash.update(workflow, %{definition: replacement}, action: :replace_definition)

    assert updated.lock_version == 2

    assert {:error, error} =
             Ash.update(stale, %{definition: definition("lost")}, action: :replace_definition)

    assert Exception.message(error) =~ "stale"
  end

  test "database rejects cross-workflow dependencies and persisted cycles" do
    {_workflow_a, task_a} = hierarchy("a")
    {_workflow_b, task_b} = hierarchy("b")

    assert {:error, error} =
             Ash.create(Dependency, %{
               predecessor_id: task_a.id,
               successor_id: task_b.id
             })

    assert Exception.message(error) =~ "same workflow"

    workflow = workflow_for("cycle")
    first = task_for(workflow, "first")
    second = task_for(workflow, "second")
    third = task_for(workflow, "third")

    assert {:ok, _} =
             Ash.create(Dependency, %{predecessor_id: first.id, successor_id: second.id})

    assert {:ok, _} =
             Ash.create(Dependency, %{predecessor_id: second.id, successor_id: third.id})

    assert {:error, error} =
             Ash.create(Dependency, %{predecessor_id: third.id, successor_id: first.id})

    assert Exception.message(error) =~ "cycle"
  end

  test "database rejects direct corruption of dependency workflow metadata" do
    {workflow, first} = hierarchy("edge-workflow")
    second = task_for(workflow, "edge-workflow-second")
    {other_workflow, _other_task} = hierarchy("edge-workflow-other")

    assert {:ok, dependency} =
             Ash.create(Dependency, %{predecessor_id: first.id, successor_id: second.id})

    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             Repo.query(
               "UPDATE task_dependencies SET workflow_id = $1 WHERE id = $2",
               [Ecto.UUID.dump!(other_workflow.id), Ecto.UUID.dump!(dependency.id)],
               mode: :savepoint
             )

    assert message =~ "must match its endpoints"
  end

  test "concurrent opposing dependency inserts cannot persist a cycle" do
    workflow = workflow_for("concurrent")
    first = task_for(workflow, "concurrent-first")
    second = task_for(workflow, "concurrent-second")

    insert = fn predecessor, successor ->
      Repo.query(
        """
        INSERT INTO task_dependencies (predecessor_id, successor_id)
        VALUES ($1::text::uuid, $2::text::uuid)
        """,
        [predecessor, successor]
      )
    end

    results =
      [{first.id, second.id}, {second.id, first.id}]
      |> Elixir.Task.async_stream(
        fn {predecessor, successor} -> insert.(predecessor, successor) end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Postgrex.Error{}}, &1)) == 1

    assert %{rows: [[1]]} =
             Repo.query!(
               "SELECT count(*) FROM task_dependencies WHERE workflow_id = $1::text::uuid",
               [workflow.id]
             )
  end

  test "all Ash start entry points reject incomplete task predecessors" do
    workflow = workflow_for("ash-start")
    predecessor = task_for(workflow, "ash-predecessor")
    successor = task_for(workflow, "ash-successor")

    assert {:ok, _} =
             Ash.create(Dependency, %{predecessor_id: predecessor.id, successor_id: successor.id})

    successor =
      Enum.reduce([:proposed, :queued, :ready], successor, fn state, current ->
        Ash.update!(current, %{to_state: state}, action: :transition)
      end)

    assert {:error, transition_error} =
             Ash.update(successor, %{to_state: :in_progress}, action: :transition)

    assert Exception.message(transition_error) =~ "incomplete predecessors"

    assert {:error, move_error} =
             Ash.update(successor, %{to_state: :in_progress}, action: :move)

    assert Exception.message(move_error) =~ "incomplete predecessors"

    assert {:error, %Postgrex.Error{postgres: %{message: "task has incomplete predecessors"}}} =
             Repo.query(
               "UPDATE workflow_tasks SET state = 'in_progress' WHERE id = $1::text::uuid",
               [successor.id],
               mode: :savepoint
             )
  end

  test "database enforces TODO dependency ownership and cycles for direct Ash callers" do
    workflow = workflow_for("todo-integrity")
    first_task = task_for(workflow, "todo-first-task")
    second_task = task_for(workflow, "todo-second-task")

    first =
      Ash.create!(Todo, %{task_id: first_task.id, todo_id: "first", body: "First", position: 1})

    second =
      Ash.create!(Todo, %{task_id: first_task.id, todo_id: "second", body: "Second", position: 2})

    foreign =
      Ash.create!(Todo, %{
        task_id: second_task.id,
        todo_id: "foreign",
        body: "Foreign",
        position: 1
      })

    assert {:error, ownership_error} =
             Ash.create(TodoDependency, %{
               task_id: first_task.id,
               predecessor_id: foreign.id,
               successor_id: second.id
             })

    assert Exception.message(ownership_error) =~ "same task"

    assert {:ok, _} =
             Ash.create(TodoDependency, %{
               task_id: first_task.id,
               predecessor_id: first.id,
               successor_id: second.id
             })

    assert {:error, cycle_error} =
             Ash.create(TodoDependency, %{
               task_id: first_task.id,
               predecessor_id: second.id,
               successor_id: first.id
             })

    assert Exception.message(cycle_error) =~ "cycle"
  end

  test "concurrent opposing TODO dependency inserts cannot persist a cycle" do
    workflow = workflow_for("todo-concurrent")
    task = task_for(workflow, "todo-concurrent-task")
    first = Ash.create!(Todo, %{task_id: task.id, todo_id: "one", body: "One", position: 1})
    second = Ash.create!(Todo, %{task_id: task.id, todo_id: "two", body: "Two", position: 2})

    insert = fn predecessor, successor ->
      Repo.query(
        "INSERT INTO task_todo_dependencies (task_id, predecessor_id, successor_id) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid)",
        [task.id, predecessor, successor]
      )
    end

    results =
      [{first.id, second.id}, {second.id, first.id}]
      |> Elixir.Task.async_stream(
        fn {predecessor, successor} -> insert.(predecessor, successor) end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Postgrex.Error{}}, &1)) == 1
  end

  test "foreign keys prevent deleting a task that owns checklist or dependency state" do
    workflow = workflow_for("deletion")
    first = task_for(workflow, "deletion-first")
    second = task_for(workflow, "deletion-second")

    assert {:ok, _} =
             Ash.create(Dependency, %{predecessor_id: first.id, successor_id: second.id})

    assert {:error, %Postgrex.Error{}} =
             Repo.query("DELETE FROM workflow_tasks WHERE id = $1::text::uuid", [first.id])
  end

  defp hierarchy(suffix \\ "main") do
    workflow = workflow_for(suffix)
    {workflow, task_for(workflow, "task-#{suffix}")}
  end

  defp workflow_for(suffix) do
    {:ok, project} =
      Ash.create(Project, %{key: "project-#{suffix}", name: "Project #{suffix}"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{
        project_id: project.id,
        key: "roadmap-#{suffix}",
        name: "Roadmap #{suffix}"
      })

    {:ok, workflow} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "workflow-#{suffix}",
        name: "Workflow #{suffix}",
        definition: definition("definition-#{suffix}")
      })

    workflow
  end

  defp task_for(workflow, suffix) do
    {:ok, task} =
      Ash.create(Task, %{
        workflow_id: workflow.id,
        task_id: "tsk-20260727T034000Z-#{String.pad_leading(suffix, 8, "0")}",
        title: "Task #{suffix}",
        definition_of_done: "Persistence checks pass",
        runner: :oban
      })

    task
  end

  defp definition(id) do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: id, kind: :oban}]})
    definition
  end
end
