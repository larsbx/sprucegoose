defmodule Orchestrator.BoardMetadataTest do
  use Orchestrator.DataCase, async: false

  alias Orchestrator.Workflows.{
    Board,
    BoardColumn,
    Definition,
    Project,
    Roadmap,
    SavedFilter,
    Task,
    Workflow
  }

  test "board metadata, typed custom fields, and saved filters persist" do
    %{task: task, board: board, column: column} = fixture("metadata")

    custom_fields = %{
      "estimate" => %{"type" => "number", "value" => 3},
      "customer_visible" => %{"type" => "boolean", "value" => true}
    }

    assert {:ok, updated} =
             Ash.update(
               task,
               %{
                 board_id: board.id,
                 column_id: column.id,
                 rank: "a0",
                 priority: 2,
                 assignees: ["agent:jimbo"],
                 labels: ["roadmap", "kanban"],
                 custom_fields: custom_fields
               },
               action: :update_board_metadata
             )

    assert updated.board_revision == 2
    assert updated.custom_fields == custom_fields
    assert updated.assignees == ["agent:jimbo"]
    assert updated.labels == ["roadmap", "kanban"]

    assert {:ok, filter} =
             Ash.create(SavedFilter, %{
               board_id: board.id,
               name: "My active work",
               criteria: %{"assignee" => "agent:jimbo", "state" => ["ready", "in_progress"]}
             })

    assert filter.criteria["assignee"] == "agent:jimbo"
  end

  test "concurrent board edits reject a stale revision" do
    %{task: task, board: board, column: column} = fixture("concurrency")

    updates =
      ["first", "second"]
      |> Elixir.Task.async_stream(
        fn rank ->
          Ash.update(
            task,
            %{board_id: board.id, column_id: column.id, rank: rank},
            action: :update_board_metadata
          )
        end,
        max_concurrency: 2
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(updates, &match?({:ok, _}, &1)) == 1
    assert Enum.count(updates, &match?({:error, _}, &1)) == 1

    assert Enum.any?(updates, fn
             {:error, error} -> Exception.message(error) =~ "stale"
             _ -> false
           end)
  end

  test "database rejects a column from another board" do
    %{task: task, board: board} = fixture("membership-a")
    %{column: foreign_column} = fixture("membership-b")

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query(
               """
               UPDATE workflow_tasks
               SET board_id = $1::text::uuid, column_id = $2::text::uuid
               WHERE id = $3::text::uuid
               """,
               [board.id, foreign_column.id, task.id]
             )
  end

  test "invalid custom values and filter keys fail closed" do
    %{task: task, board: board, column: column} = fixture("validation")

    assert {:error, custom_error} =
             Ash.update(
               task,
               %{
                 board_id: board.id,
                 column_id: column.id,
                 custom_fields: %{"estimate" => %{"type" => "number", "value" => "three"}}
               },
               action: :update_board_metadata
             )

    assert Exception.message(custom_error) =~ "invalid typed value"

    assert {:error, filter_error} =
             Ash.create(SavedFilter, %{
               board_id: board.id,
               name: "Unsafe",
               criteria: %{"sql" => "drop table workflow_tasks"}
             })

    assert Exception.message(filter_error) =~ "unsupported filter keys"
  end

  test "the unified task model has no parallel issue resource or table" do
    refute Code.ensure_loaded?(Orchestrator.Workflows.Issue)

    assert %{rows: [[nil]]} =
             Repo.query!("SELECT to_regclass('public.issues')")
  end

  defp fixture(suffix) do
    {:ok, project} =
      Ash.create(Project, %{key: "project-#{suffix}", name: "Project #{suffix}"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{
        project_id: project.id,
        key: "roadmap-#{suffix}",
        name: "Roadmap #{suffix}"
      })

    {:ok, definition} =
      Definition.parse(%{tasks: [%{id: "task-#{suffix}", kind: :oban}]})

    {:ok, workflow} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "workflow-#{suffix}",
        name: "Workflow #{suffix}",
        definition: definition
      })

    {:ok, board} =
      Ash.create(Board, %{workflow_id: workflow.id, key: "main", name: "Main"})

    {:ok, column} =
      Ash.create(BoardColumn, %{
        board_id: board.id,
        key: "inbox",
        name: "Inbox",
        position: 1,
        task_state: :inbox
      })

    {:ok, task} =
      Ash.create(Task, %{
        workflow_id: workflow.id,
        task_id:
          "tsk-20260727T150000Z-#{String.slice(:crypto.hash(:sha256, suffix) |> Base.encode16(case: :lower), 0, 8)}",
        title: "Task #{suffix}",
        definition_of_done: "Board metadata tests pass",
        runner: :oban
      })

    %{task: task, board: board, column: column}
  end
end
