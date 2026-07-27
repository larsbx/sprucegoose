defmodule SpruceGoose.PostCutoverHardeningTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Ledger
  alias SpruceGoose.Workflows.{Board, BoardColumn, Definition, Project, Roadmap, Task, Workflow}

  test "PC-01: completed authority cutover is immutable and import stays disabled" do
    Repo.query!(
      "UPDATE orchestrator_authority SET mode = 'ash', cutover_at = now() WHERE id = TRUE"
    )

    assert {:error, %Postgrex.Error{}} =
             Repo.query("UPDATE orchestrator_authority SET mode = 'tuxedo' WHERE id = TRUE")

    assert {:error, %Postgrex.Error{}} =
             Repo.query("UPDATE orchestrator_authority SET cutover_at = NULL WHERE id = TRUE")

    assert {:error, "ledger import is disabled while ash is authoritative"} =
             Ledger.import("/home/admin-papa/tasks/todo.txt")
  end

  test "PC-02/06: terminal TODO admission fails and concurrent admission is idempotent" do
    %{task: task} = fixture("todos")
    task = advance(task, [:proposed, :queued, :ready, :in_progress, :completed])

    assert {:error, _} = Executor.run({:add_todo, task.task_id, "too late"})

    assert {:error, %Postgrex.Error{}} =
             Repo.query(
               """
               INSERT INTO task_todos
                 (id, task_id, todo_id, body, position, completed, inserted_at, updated_at)
               VALUES (gen_random_uuid(), $1::text::uuid, 'late', 'late', 1, FALSE, now(), now())
               """,
               [task.id]
             )

    %{task: open_task} = fixture("todo-race")

    results =
      1..8
      |> Elixir.Task.async_stream(
        fn _ -> Executor.run({:add_todo, open_task.task_id, "same body"}) end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert results |> Enum.map(fn {:ok, todo} -> todo.id end) |> Enum.uniq() |> length() == 1

    %{task: different_task} = fixture("todo-different")

    positions =
      ["first", "second"]
      |> Elixir.Task.async_stream(
        fn body -> Executor.run({:add_todo, different_task.task_id, body}) end,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, {:ok, todo}} -> todo.position end)

    assert Enum.sort(positions) == [1, 2]

    %{task: racing_task} = fixture("todo-completion-race")
    racing_task = advance(racing_task, [:proposed, :queued, :ready, :in_progress])

    race_results =
      [
        fn ->
          Repo.query(
            "UPDATE workflow_tasks SET state = 'completed' WHERE id = $1::text::uuid",
            [racing_task.id]
          )
        end,
        fn ->
          Repo.query(
            """
            INSERT INTO task_todos
              (id, task_id, todo_id, body, position, completed, inserted_at, updated_at)
            VALUES (gen_random_uuid(), $1::text::uuid, 'race', 'race', 1, FALSE, now(), now())
            """,
            [racing_task.id]
          )
        end
      ]
      |> Elixir.Task.async_stream(fn operation -> operation.() end, max_concurrency: 2)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(race_results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(race_results, &match?({:error, _}, &1)) == 1

    assert %{rows: [[false]]} =
             Repo.query!(
               """
               SELECT task.state = 'completed' AND EXISTS (
                 SELECT 1 FROM task_todos todo
                 WHERE todo.task_id = task.id AND todo.completed = FALSE
               )
               FROM workflow_tasks task
               WHERE task.id = $1::text::uuid
               """,
               [racing_task.id]
             )
  end

  test "PC-03/04: workflow and lifecycle stay coherent with board placement" do
    %{task: task, board: board, column: ready} = fixture("coherent", :ready)
    %{board: foreign_board, column: foreign_column} = fixture("foreign", :ready)
    task = advance(task, [:proposed, :queued, :ready])

    assert {:ok, placed} =
             Ash.update(
               task,
               %{board_id: board.id, column_id: ready.id, rank: "a"},
               action: :update_board_metadata
             )

    assert {:error, _} =
             Ash.update(
               task,
               %{board_id: foreign_board.id, column_id: foreign_column.id, rank: "b"},
               action: :update_board_metadata
             )

    assert {:error, %Postgrex.Error{}} =
             Repo.query(
               """
               UPDATE workflow_tasks
               SET board_id = $1::text::uuid, column_id = $2::text::uuid
               WHERE id = $3::text::uuid
               """,
               [foreign_board.id, foreign_column.id, task.id]
             )

    {:ok, in_progress_column} =
      Ash.create(BoardColumn, %{
        board_id: board.id,
        key: "doing",
        name: "Doing",
        position: 2,
        task_state: :in_progress
      })

    assert {:ok, moved} =
             Ash.update(placed, %{to_state: :in_progress}, action: :transition)

    assert moved.state == :in_progress
    assert moved.column_id == in_progress_column.id

    assert {:error, %Postgrex.Error{}} =
             Repo.query(
               "UPDATE workflow_tasks SET state = 'completed' WHERE id = $1::text::uuid",
               [task.id]
             )
  end

  test "PC-07/09: reasons and bounded typed metadata fail closed" do
    %{task: task, board: board, column: column} = fixture("validation", :inbox)

    assert {:error, _} = Ash.update(task, %{to_state: :cancelled}, action: :transition)

    for metadata <- [
          %{priority: -1},
          %{priority: 6},
          %{rank: String.duplicate("x", 129)},
          %{due_at: "not-a-date"},
          %{labels: List.duplicate("x", 51)},
          %{custom_fields: %{"date" => %{"type" => "date", "value" => "yesterday"}}}
        ] do
      input = Map.merge(%{board_id: board.id, column_id: column.id}, metadata)

      case Ash.update(task, input, action: :update_board_metadata) do
        {:error, _} -> :ok
        {:ok, _} -> flunk("metadata unexpectedly accepted: #{inspect(metadata)}")
      end
    end
  end

  test "PC-05: canonical CLI administers boards, columns, moves, metadata, and filters" do
    %{task: task, project: project, roadmap: roadmap, workflow: workflow} = fixture("cli")

    assert {:ok, board} =
             Executor.run({
               :add_board,
               project.key,
               roadmap.key,
               workflow.workflow_id,
               "operator",
               "Operator board"
             })

    assert {:ok, %{boards: boards}} =
             Executor.run({
               :list_boards,
               project.key,
               roadmap.key,
               workflow.workflow_id
             })

    assert Enum.any?(boards, &(&1.id == board.id))

    assert {:ok, column} =
             Executor.run({:add_column, board.id, "inbox", "1", "inbox", "Inbox"})

    assert {:ok, %{columns: [%{id: column_id}]}} =
             Executor.run({:list_columns, board.id})

    assert column_id == column.id

    assert {:ok, moved} =
             Executor.run({:move_task, task.task_id, board.id, column.id, "a0"})

    assert moved.board_id == board.id
    assert moved.column_id == column.id

    assert {:ok, updated} =
             Executor.run({
               :update_task_metadata,
               task.task_id,
               ~s({"board_id":"#{board.id}","column_id":"#{column.id}","priority":2,"assignees":["jimbo"],"labels":["audit"]})
             })

    assert updated.priority == 2

    assert {:ok, filter} =
             Executor.run({:add_filter, board.id, "mine", ~s({"assignee":"jimbo"})})

    assert {:ok, %{filters: [_]}} = Executor.run({:list_filters, board.id})
    assert {:ok, %{tasks: [%{id: task_id}]}} = Executor.run({:apply_filter, filter.id})
    assert task_id == task.task_id
  end

  defp fixture(suffix, column_state \\ :inbox) do
    {:ok, project} = Ash.create(Project, %{key: "pc-#{suffix}", name: "PC #{suffix}"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{
        project_id: project.id,
        key: "pc-#{suffix}",
        name: "PC #{suffix}"
      })

    {:ok, definition} = Definition.parse(%{tasks: [%{id: suffix, kind: :oban}]})

    {:ok, workflow} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "pc-#{suffix}",
        name: "PC #{suffix}",
        definition: definition
      })

    {:ok, board} =
      Ash.create(Board, %{workflow_id: workflow.id, key: "main", name: "Main"})

    {:ok, column} =
      Ash.create(BoardColumn, %{
        board_id: board.id,
        key: Atom.to_string(column_state),
        name: Atom.to_string(column_state),
        position: 1,
        task_state: column_state
      })

    {:ok, task} =
      Ash.create(Task, %{
        workflow_id: workflow.id,
        task_id:
          "tsk-20260727T191000Z-#{String.slice(:crypto.hash(:sha256, suffix) |> Base.encode16(case: :lower), 0, 8)}",
        title: "PC #{suffix}",
        definition_of_done: "Post-cutover invariant holds",
        runner: :oban
      })

    %{
      project: project,
      roadmap: roadmap,
      workflow: workflow,
      task: task,
      board: board,
      column: column
    }
  end

  defp advance(task, states) do
    Enum.reduce(states, task, fn state, current ->
      {:ok, current} = Ash.update(current, %{to_state: state}, action: :transition)
      current
    end)
  end
end
