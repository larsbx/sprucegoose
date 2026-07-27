defmodule Orchestrator.CLIDatabaseTest do
  use Orchestrator.DataCase, async: false

  alias Orchestrator.CLI.Executor
  alias Orchestrator.Workflows.{Definition, Dependency, Project, Roadmap, Task, Workflow}

  test "CLI task admission writes to PostgreSQL and show reads it back" do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "admit", kind: :oban}]})
    {:ok, project} = Ash.create(Project, %{key: "pi", name: "Pi"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{
        project_id: project.id,
        key: "orchestrator",
        name: "Orchestrator"
      })

    {:ok, _workflow} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "audit-fixes",
        name: "Audit fixes",
        definition: definition
      })

    assert {:ok, created} =
             Executor.run({
               :add_task,
               %{
                 project: "pi",
                 roadmap: "orchestrator",
                 workflow: "audit-fixes",
                 task_type: :task,
                 title: "Persist through CLI",
                 definition_of_done: "The record is readable"
               }
             })

    assert created.title == "Persist through CLI"
    assert {:ok, shown} = Executor.run({:show_task, created.id})
    assert shown == created
  end

  test "CLI list, lifecycle, and link commands replace taskctl operational paths" do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "operate", kind: :openclaw}]})
    {:ok, project} = Ash.create(Project, %{key: "operations", name: "Operations"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{project_id: project.id, key: "cutover", name: "Cutover"})

    {:ok, workflow} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "cli",
        name: "CLI",
        definition: definition
      })

    {:ok, task} =
      Ash.create(Task, %{
        workflow_id: workflow.id,
        task_id: "tsk-20260727T044500Z-1234abcd",
        title: "Operate through Ash",
        definition_of_done: "Lifecycle passes",
        runner: :openclaw
      })

    {:ok, successor} =
      Ash.create(Task, %{
        workflow_id: workflow.id,
        task_id: "tsk-20260727T044501Z-1234abcd",
        title: "Run after predecessor",
        definition_of_done: "Predecessor is complete",
        runner: :openclaw
      })

    {:ok, _edge} =
      Ash.create(Dependency, %{predecessor_id: task.id, successor_id: successor.id})

    assert {:error, _} = Executor.run({:transition_task, task.task_id, :completed, nil})

    for target <- [:proposed, :queued, :ready] do
      assert {:ok, %{state: ^target}} =
               Executor.run({:transition_task, successor.task_id, target, nil})
    end

    assert {:error, "task has incomplete predecessors"} =
             Executor.run({:transition_task, successor.task_id, :in_progress, nil})

    for target <- [:proposed, :queued, :ready, :in_progress] do
      assert {:ok, %{state: ^target}} =
               Executor.run({:transition_task, task.task_id, target, nil})
    end

    assert {:ok, %{state: :waiting}} =
             Executor.run({:transition_task, task.task_id, :waiting, "operator review"})

    assert {:ok, linked} =
             Executor.run({:link_task, task.task_id, "evidence", "/tmp/proof"})

    assert linked.lock_version > 1
    assert {:ok, %{tasks: [%{id: id, state: :waiting}]}} = Executor.run({:list_tasks, "waiting"})
    assert id == task.task_id

    for target <- [:ready, :in_progress, :completed] do
      assert {:ok, %{state: ^target}} =
               Executor.run({:transition_task, task.task_id, target, nil})
    end

    assert {:ok, %{state: :in_progress}} =
             Executor.run({:transition_task, successor.task_id, :in_progress, nil})

    assert {:ok, todo} = Executor.run({:add_todo, successor.task_id, "Attach evidence"})
    assert {:ok, ^todo} = Executor.run({:add_todo, successor.task_id, "Attach evidence"})
    assert {:ok, %{todos: [^todo]}} = Executor.run({:list_todos, successor.task_id})

    assert {:ok, %{completed: true}} =
             Executor.run({:complete_todo, successor.task_id, todo.id})
  end

  test "CLI inbox capture is idempotent and remains non-executable" do
    assert {:ok, first} = Executor.run({:add_inbox, "Unclassified operator note"})
    assert {:ok, second} = Executor.run({:add_inbox, "Unclassified operator note"})
    assert first == second
    assert first.state == :pending

    assert {:ok, %{items: [listed]}} = Executor.run(:list_inbox)
    assert listed == first
  end
end
