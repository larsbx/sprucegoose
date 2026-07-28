defmodule SpruceGoose.TransactionalOutboxTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Outbox.{Dispatcher, Event}
  alias SpruceGoose.Repo

  setup do
    Repo.delete_all(Event)
    :ok
  end

  test "task and idempotent inbox writes produce one committed outbox event per revision" do
    %{task: task} = fixture()

    assert [%Event{event_key: "task:" <> _}] = Repo.all(Event)

    assert {:ok, first} = Executor.run({:add_inbox, "transactional intake"})
    assert {:ok, ^first} = Executor.run({:add_inbox, "transactional intake"})

    inbox_events =
      Event
      |> where([event], event.aggregate_type == "inbox")
      |> Repo.all()

    assert [%Event{aggregate_id: aggregate_id, event_type: "inbox.captured"}] = inbox_events
    assert aggregate_id == first.id

    assert {:ok, _} = Executor.run({:link_task, task.task_id, "evidence", "outbox-proof"})

    assert 2 ==
             Event
             |> where([event], event.aggregate_id == ^task.task_id)
             |> Repo.aggregate(:count)

    before_rollback = Repo.aggregate(Event, :count)

    assert {:error, :forced} =
             Repo.transaction(fn ->
               Repo.query!("UPDATE workflow_tasks SET description = $1 WHERE task_id = $2", [
                 "must roll back",
                 task.task_id
               ])

               Repo.rollback(:forced)
             end)

    assert Repo.aggregate(Event, :count) == before_rollback
  end

  test "dispatcher marks committed rows and records failed delivery attempts" do
    fixture()

    assert {:ok, [{:error, _}]} = Dispatcher.dispatch_batch(fn _ -> {:error, :offline} end)
    assert %Event{status: :pending, attempts: 1, last_error: error} = Repo.one!(Event)
    assert error =~ "offline"

    assert {:ok, [{:ok, _}]} = Dispatcher.dispatch_batch(fn _ -> :ok end)

    assert %Event{status: :dispatched, attempts: 2, dispatched_at: dispatched_at} =
             Repo.one!(Event)

    assert dispatched_at
  end

  test "only one dispatcher job may be scheduled at a time" do
    assert {:ok, first} = Dispatcher.enqueue()
    assert {:ok, second} = Dispatcher.enqueue()
    assert first.id == second.id
    assert second.conflict?
  end

  defp fixture do
    suffix = System.unique_integer([:positive])

    project =
      Ash.create!(SpruceGoose.Workflows.Project, %{key: "outbox-#{suffix}", name: "Outbox"})

    roadmap =
      Ash.create!(SpruceGoose.Workflows.Roadmap, %{
        project_id: project.id,
        key: "outbox-#{suffix}",
        name: "Outbox"
      })

    workflow =
      Ash.create!(SpruceGoose.Workflows.Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "outbox-#{suffix}",
        name: "Outbox",
        definition: %{
          schema_version: 1,
          tasks: [%{id: "work", kind: :oban, depends_on: [], input: %{}}]
        }
      })

    task_input = %{
      workflow_id: workflow.id,
      task_id: SpruceGoose.TaskId.generate(),
      task_type: :task,
      title: "Outbox task",
      definition_of_done: "Outbox proof passes.",
      runner: :oban
    }

    task_input =
      if Ash.Resource.Info.attribute(SpruceGoose.Workflows.Task, :sop_gate_required),
        do: Map.put(task_input, :sop_gate_required, false),
        else: task_input

    task =
      Ash.create!(SpruceGoose.Workflows.Task, task_input)

    %{task: task}
  end
end
