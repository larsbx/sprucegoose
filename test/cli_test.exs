defmodule Orchestrator.CLITest do
  use ExUnit.Case, async: true

  alias Orchestrator.CLI.Command
  alias Orchestrator.TaskId

  test "generates and validates the spec task ID schema" do
    now = ~U[2026-07-27 01:23:51Z]
    id = TaskId.generate(now, <<0xEA, 0x5B, 0xA1, 0xB1>>)

    assert id == "tsk-20260727T012351Z-ea5ba1b1"
    assert TaskId.valid?(id)
    refute TaskId.valid?("tsk-20260231T012351Z-ea5ba1b1")
    refute TaskId.valid?("tsk-20260727T012351Z-EA5BA1B1")
    refute TaskId.valid?("114")
  end

  test "task admission requires typed membership, DoD, type, and title" do
    assert {:ok, {:add_task, task}} =
             Command.parse([
               "task",
               "add",
               "--project",
               "pi",
               "--roadmap",
               "buzz-agent-collaboration-plane",
               "--workflow",
               "buzz-integration",
               "--dod",
               "focused checks pass",
               "--type",
               "diagnosis",
               "Diagnose",
               "the",
               "boundary"
             ])

    assert task.project == "pi"
    assert task.roadmap == "buzz-agent-collaboration-plane"
    assert task.workflow == "buzz-integration"
    assert task.definition_of_done == "focused checks pass"
    assert task.task_type == :diagnosis
    assert task.title == "Diagnose the boundary"

    assert {:ok, {:add_task, %{task_type: :task}}} =
             Command.parse([
               "task",
               "add",
               "--project",
               "pi",
               "--roadmap",
               "buzz-agent-collaboration-plane",
               "--workflow",
               "buzz-integration",
               "--dod",
               "focused checks pass",
               "Default task"
             ])

    for missing <- ["project", "roadmap", "workflow", "dod"] do
      args =
        [
          "task",
          "add",
          "--project",
          "pi",
          "--roadmap",
          "roadmap",
          "--workflow",
          "workflow",
          "--dod",
          "done",
          "title"
        ]
        |> drop_option("--#{missing}")

      assert {:error, _} = Command.parse(args)
    end
  end

  test "rejects unknown task types and missing titles" do
    base = [
      "task",
      "add",
      "--project",
      "pi",
      "--roadmap",
      "roadmap",
      "--workflow",
      "workflow",
      "--dod",
      "done"
    ]

    assert {:error, "task title is required"} = Command.parse(base)

    assert {:error, "--type must be task or diagnosis"} =
             Command.parse(base ++ ["--type", "shell", "x"])
  end

  test "parses operator lifecycle commands" do
    id = "tsk-20260727T044500Z-1234abcd"

    assert {:ok, {:list_tasks, "waiting"}} = Command.parse(["task", "list", "--state", "waiting"])

    assert {:ok, {:transition_task, ^id, :proposed, nil}} =
             Command.parse(["task", "propose", id])

    assert {:ok, {:transition_task, ^id, :queued, nil}} = Command.parse(["task", "queue", id])
    assert {:ok, {:transition_task, ^id, :ready, nil}} = Command.parse(["task", "ready", id])

    assert {:ok, {:transition_task, ^id, :in_progress, nil}} =
             Command.parse(["task", "start", id])

    assert {:ok, {:transition_task, ^id, :waiting, "operator review"}} =
             Command.parse(["task", "wait", id, "operator", "review"])

    assert {:ok, {:link_task, ^id, "evidence", "/tmp/proof"}} =
             Command.parse(["task", "link", id, "evidence", "/tmp/proof"])

    assert {:ok, {:transition_task, ^id, :completed, nil}} = Command.parse(["task", "done", id])

    assert {:ok, {:transition_task, ^id, :cancelled, "superseded"}} =
             Command.parse(["task", "cancel", id, "superseded"])

    assert {:error, :usage} = Command.parse(["task", "cancel", id])
  end

  test "parses governed Kanban commands" do
    assert {:ok, {:add_board, "pi", "buzz", "integration", "main", "Main board"}} =
             Command.parse(["board", "add", "pi", "buzz", "integration", "main", "Main", "board"])

    assert {:ok, {:list_boards, "pi", "buzz", "integration"}} =
             Command.parse(["board", "list", "pi", "buzz", "integration"])

    assert {:ok, {:add_column, "board-id", "ready", "1", "ready", "Ready work"}} =
             Command.parse(["column", "add", "board-id", "ready", "1", "ready", "Ready", "work"])

    assert {:ok, {:move_task, "task-id", "board-id", "column-id", "a0"}} =
             Command.parse(["task", "move", "task-id", "board-id", "column-id", "a0"])

    assert {:ok, {:update_task_metadata, "task-id", ~s({"priority":2})}} =
             Command.parse(["task", "metadata", "task-id", ~s({"priority":2})])

    assert {:ok, {:add_filter, "board-id", "mine", ~s({"assignee":"jimbo"})}} =
             Command.parse(["filter", "add", "board-id", "mine", ~s({"assignee":"jimbo"})])

    assert {:ok, {:apply_filter, "filter-id"}} =
             Command.parse(["filter", "apply", "filter-id"])
  end

  test "parses fail-closed inbox capture" do
    assert {:ok, {:add_inbox, "Unclassified operator note"}} =
             Command.parse(["inbox", "add", "Unclassified", "operator", "note"])

    assert {:ok, :list_inbox} = Command.parse(["inbox", "list"])
    assert {:error, :usage} = Command.parse(["inbox", "add"])
  end

  test "parses subordinate TODO commands" do
    id = "tsk-20260727T044500Z-1234abcd"

    assert {:ok, {:add_todo, ^id, "Attach evidence"}} =
             Command.parse(["todo", "add", id, "Attach", "evidence"])

    assert {:ok, {:list_todos, ^id}} = Command.parse(["todo", "list", id])

    assert {:ok, {:complete_todo, ^id, "todo-abc"}} =
             Command.parse(["todo", "done", id, "todo-abc"])
  end

  defp drop_option(args, option) do
    case Enum.split_while(args, &(&1 != option)) do
      {left, [_option, _value | right]} -> left ++ right
      _ -> args
    end
  end
end
