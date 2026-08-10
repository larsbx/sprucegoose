defmodule SpruceGoose.TransactionalOutboxTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Actors.Actor
  alias SpruceGoose.Outbox.{Dispatcher, Event}
  alias SpruceGoose.Repo

  defmodule HandlerStub do
    def deliver(_event), do: :ok
  end

  setup do
    Repo.delete_all(Event)
    :ok
  end

  test "task and inbox writes produce one committed outbox event per capture" do
    %{task: task} = fixture()

    assert [%Event{event_key: "task:" <> _}] = Repo.all(Event)

    # Captures are identified by a generated id, not sha256(body), so two
    # captures with identical text are two distinct records. Outbox dedup does
    # not rely on that collapse: the trigger keys ON CONFLICT on
    # 'inbox:' || capture_id, so each capture still yields exactly one event.
    assert {:ok, first} = Executor.run({:add_inbox, "transactional intake"})
    assert {:ok, second} = Executor.run({:add_inbox, "transactional intake"})
    assert first.id != second.id

    inbox_events =
      Event
      |> where([event], event.aggregate_type == "inbox")
      |> order_by([event], event.inserted_at)
      |> Repo.all()

    assert [
             %Event{aggregate_id: first_aggregate, event_type: "inbox.captured"},
             %Event{aggregate_id: second_aggregate, event_type: "inbox.captured"}
           ] = inbox_events

    assert first_aggregate == first.id
    assert second_aggregate == second.id

    # Re-capturing an existing id is still deduplicated by the trigger.
    assert 2 ==
             Event
             |> where([event], event.aggregate_type == "inbox")
             |> Repo.aggregate(:count)

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
    before = DateTime.utc_now()

    assert {:ok, [{:error, _}]} = Dispatcher.dispatch_batch(fn _ -> {:error, :offline} end)

    assert %Event{status: :pending, attempts: 1, last_error: error, available_at: available_at} =
             Repo.one!(Event)

    assert error =~ "offline"
    assert DateTime.compare(available_at, before) == :gt

    Repo.update_all(Event, set: [available_at: DateTime.utc_now()])
    assert {:ok, [{:ok, _}]} = Dispatcher.dispatch_batch(fn _ -> :ok end)

    assert %Event{status: :dispatched, attempts: 2, dispatched_at: dispatched_at} =
             Repo.one!(Event)

    assert dispatched_at
  end

  test "dispatcher dead-letters an event after the bounded attempt limit" do
    fixture()
    Repo.update_all(Event, set: [attempts: 19])

    assert {:ok, [{:error, _}]} = Dispatcher.dispatch_batch(fn _ -> {:error, :offline} end)
    assert %Event{status: :failed, attempts: 20} = Repo.one!(Event)
    assert {:ok, []} = Dispatcher.dispatch_batch(fn _ -> :ok end)
  end

  test "one Oban cron entry defines consecutive future dispatcher runs" do
    assert [{schedule, SpruceGoose.Outbox.Dispatcher}] = Dispatcher.cron_config()

    expression = Oban.Cron.Expression.parse!(schedule)
    first = Oban.Cron.Expression.next_at(expression, ~U[2026-08-10 02:00:01Z])
    second = Oban.Cron.Expression.next_at(expression, first)
    third = Oban.Cron.Expression.next_at(expression, second)

    assert [first, second, third] == [
             ~U[2026-08-10 02:01:00Z],
             ~U[2026-08-10 02:02:00Z],
             ~U[2026-08-10 02:03:00Z]
           ]

    Application.put_env(:spruce_goose, :outbox_handler, fn _ -> :ok end)
    on_exit(fn -> Application.put_env(:spruce_goose, :outbox_handler, nil) end)

    for _ <- 1..3 do
      assert :ok = Dispatcher.perform(%Oban.Job{})
    end

    assert [] =
             Oban.Job
             |> where([job], job.worker == ^to_string(Dispatcher))
             |> Repo.all()
  end

  test "enabled runtime handlers must load and export deliver/1" do
    assert :ok = Dispatcher.validate_handler(HandlerStub)

    assert {:error, message} = Dispatcher.validate_handler(String)
    assert message =~ "exports deliver/1"
  end

  test "enabled runtime configuration installs exactly one dispatcher cron entry" do
    env = %{
      "OUTBOX_DISPATCHER_ENABLED" => "true",
      "OUTBOX_HANDLER" => inspect(HandlerStub),
      "DATABASE_URL" => "ecto://postgres:postgres@localhost/spruce_goose_test",
      "TOKEN_SIGNING_SECRET" => "runtime-config-test-only",
      "SYSTEMWIDE_SOP_EXPECTED_SHA256" => String.duplicate("a", 64)
    }

    previous = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)
    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    config =
      Config.Reader.read!(Path.expand("../config/runtime.exs", __DIR__),
        env: :prod,
        target: :host
      )

    spruce_goose_config = Keyword.fetch!(config, :spruce_goose)
    assert [plugins: [{Oban.Plugins.Cron, cron_opts}]] = Keyword.fetch!(spruce_goose_config, Oban)
    assert Keyword.fetch!(cron_opts, :crontab) == Dispatcher.cron_config()
  end

  test "one poisoned event does not roll back successful sibling accounting" do
    fixture()
    fixture()

    events =
      Event
      |> order_by([event], asc: event.inserted_at)
      |> Repo.all()

    [first, second] = events
    first_id = first.id
    second_id = second.id

    assert {:ok, [{:ok, ^first_id}, {:error, ^second_id}]} =
             Dispatcher.dispatch_batch(fn
               %Event{id: ^first_id} -> :ok
               %Event{id: ^second_id} -> raise "poisoned event"
             end)

    assert %Event{status: :dispatched, attempts: 1} = Repo.get!(Event, first.id)

    assert %Event{status: :pending, attempts: 1, last_error: error} =
             Repo.get!(Event, second.id)

    assert error =~ "poisoned event"
  end

  test "a stale claimant cannot overwrite a newer lease or its accounting" do
    fixture()
    event = Repo.one!(Event)
    newer_lease = DateTime.add(DateTime.utc_now(), 300, :second)

    assert {:ok, [{:stale, event_id}]} =
             Dispatcher.dispatch_batch(
               fn _ -> :ok end,
               after_delivery: fn claimed, :ok ->
                 from(item in Event, where: item.id == ^claimed.id)
                 |> Repo.update_all(set: [available_at: newer_lease])
               end
             )

    assert event_id == event.id

    assert %Event{status: :pending, attempts: 0, available_at: ^newer_lease} =
             Repo.get!(Event, event.id)
  end

  test "crash after external success is redelivered with the same immutable key" do
    fixture()
    event = Repo.one!(Event)
    parent = self()

    Process.flag(:trap_exit, true)

    dispatcher =
      spawn_link(fn ->
        Dispatcher.dispatch_batch(
          fn delivered ->
            send(parent, {:external_success, delivered.event_key})
            :ok
          end,
          after_delivery: fn _event, :ok -> exit(:crash_before_accounting) end
        )
      end)

    assert_receive {:external_success, event_key}
    assert event_key == event.event_key
    assert_receive {:EXIT, ^dispatcher, :crash_before_accounting}

    assert %Event{status: :pending, attempts: 0, dispatched_at: nil} = Repo.get!(Event, event.id)

    Repo.update_all(Event, set: [available_at: DateTime.add(DateTime.utc_now(), -1, :second)])

    assert {:ok, [{:ok, event_id}]} =
             Dispatcher.dispatch_batch(fn delivered ->
               assert delivered.event_key == event.event_key
               :ok
             end)

    assert event_id == event.id
    assert %Event{status: :dispatched, attempts: 1} = Repo.get!(Event, event.id)
  end

  test "raise, exit, throw, timeout, and malformed results consume one attempt" do
    failure_handlers = [
      fn _ -> raise "raised" end,
      fn _ -> exit(:exited) end,
      fn _ -> throw(:thrown) end,
      fn _ -> :malformed end
    ]

    for handler <- failure_handlers do
      Repo.delete_all(Event)
      fixture()

      assert {:ok, [{:error, event_id}]} = Dispatcher.dispatch_batch(handler)
      assert %Event{status: :pending, attempts: 1, last_error: error} = Repo.get!(Event, event_id)
      assert is_binary(error) and error != ""
    end

    Repo.delete_all(Event)
    fixture()
    Application.put_env(:spruce_goose, :outbox_delivery_timeout_ms, 5)

    on_exit(fn ->
      Application.put_env(:spruce_goose, :outbox_delivery_timeout_ms, 30_000)
    end)

    assert {:ok, [{:error, event_id}]} =
             Dispatcher.dispatch_batch(fn _ -> Process.sleep(:infinity) end)

    assert %Event{status: :pending, attempts: 1, last_error: error} = Repo.get!(Event, event_id)
    assert error =~ "timeout"
  end

  test "a handler exception eventually dead-letters the event" do
    fixture()
    Repo.update_all(Event, set: [attempts: 19])

    assert {:ok, [{:error, event_id}]} =
             Dispatcher.dispatch_batch(fn _ -> raise "poisoned until dead-letter" end)

    assert %Event{status: :failed, attempts: 20, last_error: error} = Repo.get!(Event, event_id)
    assert error =~ "poisoned until dead-letter"
  end

  test "only a global admin may inspect and replay failed events" do
    fixture()
    event = Repo.one!(Event)
    Repo.update_all(Event, set: [status: :failed, attempts: 20, last_error: "offline"])

    ungranted =
      Ash.create!(Actor, %{
        name: "outbox-reader",
        kind: :agent,
        created_by: "test-system"
      })

    assert {:error, refusal} = Executor.run(:list_failed_outbox, ungranted.name)
    assert refusal =~ "require admin at global scope"

    assert {:ok, %{events: [%{id: event_id, event_key: event_key}]}} =
             Executor.run(:list_failed_outbox)

    assert event_id == event.id
    assert event_key == event.event_key

    assert {:ok, %{id: ^event_id, status: :pending, attempts: 0}} =
             Executor.run({:replay_outbox, event_id})

    assert {:ok, [{:ok, ^event_id}]} = Dispatcher.dispatch_batch(fn _ -> :ok end)
    assert %Event{status: :dispatched, attempts: 1} = Repo.get!(Event, event_id)
  end

  test "event identity and payload are immutable while delivery state may advance" do
    fixture()
    event = Repo.one!(Event)

    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             Repo.query(
               "UPDATE outbox_events SET event_type = 'tampered' WHERE id = $1",
               [Ecto.UUID.dump!(event.id)],
               mode: :savepoint
             )

    assert message == "outbox event content is immutable"
    assert {:ok, [{:ok, _}]} = Dispatcher.dispatch_batch(fn _ -> :ok end)
    assert Repo.get!(Event, event.id).status == :dispatched
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

    task =
      Ash.create!(SpruceGoose.Workflows.Task, task_input)

    %{task: task}
  end
end
