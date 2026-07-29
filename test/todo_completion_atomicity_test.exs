defmodule SpruceGoose.TodoCompletionAtomicityTest do
  @moduledoc """
  Regression cover for tsk-20260729T104852Z-cef32688.

  Question asked: is task completion atomic with respect to TODO admission?
  Could completion_requirements/1 pass while a concurrent TODO insert lands,
  leaving a :completed task with an incomplete TODO beneath it?

  Answer: no. The invariant holds, and this file pins the mechanism.

  create_todo/3 takes pg_advisory_xact_lock(task.id) and then RE-READS the task
  inside that lock before checking todo_admission_allowed/1. That in-lock
  re-read is load bearing. If completion commits first, the admission
  transaction blocks on the lock, wakes, re-reads a terminal task, and refuses.
  If admission commits first, the completion validation sees an incomplete TODO
  and refuses. One side always loses cleanly; neither can interleave.

  A true concurrency probe cannot live in the Ecto sandbox: test_helper sets
  Sandbox.mode(:manual) and DataCase checks out a SHARED owner for async: false
  tests, so spawned processes reuse one connection and queue instead of racing.
  The original harness produced 40/40 identical outcomes for exactly that
  reason, and that uniformity was the tell. These tests therefore assert the
  serialisation contract directly rather than pretending to race.

  The out-of-sandbox probe that produced the real evidence ran 120 attempts on
  separate connections with an explicit barrier and alternating start order:
    [admission: :error, completion: :ok]  -> :completed,   incomplete=0  x96
    [admission: :ok,    completion: :error] -> :in_progress, incomplete=1  x24
    violations: 0/120
  """
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor

  alias SpruceGoose.Workflows.{
    Board,
    BoardColumn,
    Definition,
    Project,
    Roadmap,
    Task,
    Todo,
    Workflow
  }

  test "completion gate refuses while any TODO is incomplete" do
    task = fixture("gate") |> advance([:proposed, :queued, :ready, :in_progress])

    {:ok, blocker} = Executor.run({:add_todo, task.task_id, "must finish first"})

    assert {:error, _} = Executor.run({:transition_task, task.task_id, :completed, nil})

    {:ok, _} = Executor.run({:complete_todo, task.task_id, blocker.id})

    assert {:ok, %{state: :completed}} =
             Executor.run({:transition_task, task.task_id, :completed, nil})
  end

  test "terminal tasks refuse further TODO admission" do
    task = fixture("terminal") |> advance([:proposed, :queued, :ready, :in_progress])

    {:ok, todo} = Executor.run({:add_todo, task.task_id, "only one"})
    {:ok, _} = Executor.run({:complete_todo, task.task_id, todo.id})
    {:ok, _} = Executor.run({:transition_task, task.task_id, :completed, nil})

    # This is the half of the invariant that closes the race window: once the
    # task is terminal, admission is refused no matter when it arrives.
    assert {:error, "cannot add TODO to terminal task"} =
             Executor.run({:add_todo, task.task_id, "after the fact"})

    assert {:ok, %{todos: todos}} = Executor.run({:list_todos, task.task_id})
    assert length(todos) == 1
  end

  test "TODO admission re-reads task state inside the advisory lock" do
    task = fixture("relock") |> advance([:proposed, :queued, :ready, :in_progress])

    {:ok, first} = Executor.run({:add_todo, task.task_id, "before completion"})
    {:ok, _} = Executor.run({:complete_todo, task.task_id, first.id})

    # Mutate state behind the executor's back, exactly as a committed
    # concurrent completion would. The stale in-memory task struct is not what
    # admission trusts; create_todo re-reads under the lock.
    Repo.query!("UPDATE workflow_tasks SET state = 'completed' WHERE id = $1::text::uuid", [
      task.id
    ])

    assert {:error, "cannot add TODO to terminal task"} =
             Executor.run({:add_todo, task.task_id, "should be refused"})

    {:ok, todos} = Ash.read(Ash.Query.filter_input(Todo, task_id: task.id))
    assert length(todos) == 1
  end

  test "cancelled tasks also refuse TODO admission" do
    task = fixture("cancelled") |> advance([:proposed, :queued, :ready, :in_progress])

    {:ok, _} = Executor.run({:transition_task, task.task_id, :cancelled, "superseded"})

    assert {:error, "cannot add TODO to terminal task"} =
             Executor.run({:add_todo, task.task_id, "too late"})
  end

  defp fixture(suffix) do
    {:ok, project} = Ash.create(Project, %{key: "at-#{suffix}", name: "AT #{suffix}"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{project_id: project.id, key: "at-#{suffix}", name: "AT #{suffix}"})

    {:ok, definition} = Definition.parse(%{tasks: [%{id: "t", kind: :oban}]})

    {:ok, workflow} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "at-#{suffix}",
        name: "AT #{suffix}",
        definition: definition
      })

    {:ok, board} = Ash.create(Board, %{workflow_id: workflow.id, key: "main", name: "Main"})

    states = ~w(inbox proposed queued ready in_progress completed cancelled)a

    for {state, position} <- Enum.with_index(states, 1) do
      {:ok, _} =
        Ash.create(BoardColumn, %{
          board_id: board.id,
          key: Atom.to_string(state),
          name: Atom.to_string(state),
          position: position,
          task_state: state
        })
    end

    {:ok, task} =
      Ash.create(Task, %{
        workflow_id: workflow.id,
        task_id: SpruceGoose.TaskId.generate(),
        title: "Atomicity #{suffix}",
        definition_of_done: "Completion is atomic with TODO admission",
        runner: :oban
      })

    task
  end

  defp advance(task, states) do
    Enum.reduce(states, task, fn state, current ->
      {:ok, updated} = Ash.update(current, %{to_state: state}, action: :transition)
      updated
    end)
  end
end
