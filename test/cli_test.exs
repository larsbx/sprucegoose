defmodule SpruceGoose.CLITest do
  use ExUnit.Case, async: true

  alias SpruceGoose.CLI
  alias SpruceGoose.CLI.Command
  alias SpruceGoose.SopGate
  alias SpruceGoose.TaskId

  test "returns scoped help for every command family and rejects unknown families" do
    families =
      ~w(id project roadmap workflow task dep todo board column filter inbox ledger outbox)

    for family <- families, help_arg <- ["help", "--help"] do
      assert {:ok, help} = CLI.run([family, help_arg])
      assert help.command == family
      assert help.usage == "sprucegoose #{family} <command> [args]"
      assert help.forms != []
    end

    assert {:ok, task_help} = CLI.run(["task", "--help"])

    assert "add --project KEY --roadmap KEY --workflow ID --priority N --dod TEXT --sop PATH [--type task|diagnosis] TITLE" in task_help.forms

    assert "list [--state S] [--project KEY] [--roadmap KEY] [--workflow ID] [--type T] [--label L] [--assignee A] [--priority N] [--text T]" in task_help.forms

    assert {:error, :usage} = CLI.run(["unknown", "--help"])
    assert {:ok, root_help} = CLI.run(["--help"])
    assert root_help.usage == "sprucegoose <command> [args]"
    assert {:ok, %{version: _}} = CLI.run(["--version"])
  end

  test "generates and validates the spec task ID schema" do
    now = ~U[2026-07-27 01:23:51Z]
    id = TaskId.generate(now, <<0xEA, 0x5B, 0xA1, 0xB1>>)

    assert id == "tsk-20260727T012351Z-ea5ba1b1"
    assert TaskId.valid?(id)
    refute TaskId.valid?("tsk-20260231T012351Z-ea5ba1b1")
    refute TaskId.valid?("tsk-20260727T012351Z-EA5BA1B1")
    refute TaskId.valid?("114")
  end

  test "parses failed-event inspection and replay commands" do
    assert {:ok, :list_failed_outbox} = Command.parse(["outbox", "failed"])

    assert {:ok, {:replay_outbox, "ad6cb708-3d90-47de-a701-19a45689f7ee"}} =
             Command.parse(["outbox", "replay", "ad6cb708-3d90-47de-a701-19a45689f7ee"])

    assert {:error, :usage} = Command.parse(["outbox", "replay"])
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
               "--priority",
               "1",
               "--dod",
               "focused checks pass",
               "--sop",
               SopGate.path(),
               "--type",
               "diagnosis",
               "Diagnose",
               "the",
               "boundary"
             ])

    assert task.project == "pi"
    assert task.roadmap == "buzz-agent-collaboration-plane"
    assert task.workflow == "buzz-integration"
    assert task.priority == 1
    assert task.definition_of_done == "focused checks pass"
    assert task.sop_path == SopGate.path()
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
               "--priority",
               "3",
               "--dod",
               "focused checks pass",
               "--sop",
               SopGate.path(),
               "Default task"
             ])

    for missing <- ["project", "roadmap", "workflow", "priority", "dod", "sop"] do
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
          "--priority",
          "3",
          "--dod",
          "done",
          "--sop",
          SopGate.path(),
          "title"
        ]
        |> drop_option("--#{missing}")

      assert {:error, _} = Command.parse(args)
    end

    for priority <- ["-1", "6"] do
      assert {:error, "--priority must be between 0 and 5"} =
               Command.parse([
                 "task",
                 "add",
                 "--project",
                 "pi",
                 "--roadmap",
                 "roadmap",
                 "--workflow",
                 "workflow",
                 "--priority",
                 priority,
                 "--dod",
                 "done",
                 "--sop",
                 SopGate.path(),
                 "title"
               ])
    end
  end

  test "parses full hierarchy admission commands" do
    assert {:ok, {:add_project, "dogfood", "Dogfood project"}} =
             Command.parse(["project", "add", "dogfood", "Dogfood", "project"])

    assert {:ok, {:add_roadmap, "dogfood", "dev", "Development roadmap"}} =
             Command.parse(["roadmap", "add", "dogfood", "dev", "Development", "roadmap"])

    definition = ~s({"tasks":[{"id":"build","kind":"oban"}]})

    assert {:ok, {:add_workflow, "dogfood", "dev", "proof", "Proof workflow", ^definition}} =
             Command.parse([
               "workflow",
               "add",
               "--project",
               "dogfood",
               "--roadmap",
               "dev",
               "--definition",
               definition,
               "proof",
               "Proof",
               "workflow"
             ])

    assert {:error, "--definition is required"} =
             Command.parse([
               "workflow",
               "add",
               "--project",
               "dogfood",
               "--roadmap",
               "dev",
               "proof",
               "Proof"
             ])
  end

  test "parses hierarchy read commands with optional scope filters" do
    assert {:ok, :list_projects} = Command.parse(["project", "list"])
    assert {:ok, {:show_project, "pi"}} = Command.parse(["project", "show", "pi"])

    assert {:ok, {:list_roadmaps, nil}} = Command.parse(["roadmap", "list"])

    assert {:ok, {:list_roadmaps, "pi"}} =
             Command.parse(["roadmap", "list", "--project", "pi"])

    assert {:ok, {:show_roadmap, "pi", "pi-platform-governance"}} =
             Command.parse(["roadmap", "show", "pi", "pi-platform-governance"])

    assert {:ok, {:list_workflows, nil, nil}} = Command.parse(["workflow", "list"])

    assert {:ok, {:list_workflows, "pi", nil}} =
             Command.parse(["workflow", "list", "--project", "pi"])

    assert {:ok, {:list_workflows, nil, "dashboard"}} =
             Command.parse(["workflow", "list", "--roadmap", "dashboard"])

    assert {:ok, {:list_workflows, "pi", "pi-platform-governance"}} =
             Command.parse([
               "workflow",
               "list",
               "--project",
               "pi",
               "--roadmap",
               "pi-platform-governance"
             ])

    assert {:ok, {:show_workflow, "pi", "pi-platform-governance", "pi-icm-doc-accuracy"}} =
             Command.parse([
               "workflow",
               "show",
               "pi",
               "pi-platform-governance",
               "pi-icm-doc-accuracy"
             ])
  end

  test "hierarchy read commands reject stray arguments and unknown options" do
    assert {:error, :usage} = Command.parse(["project", "list", "extra"])
    assert {:error, :usage} = Command.parse(["project", "show"])
    assert {:error, :usage} = Command.parse(["roadmap", "show", "pi"])
    assert {:error, :usage} = Command.parse(["workflow", "show", "pi", "roadmap"])

    assert {:error, "invalid list arguments"} = Command.parse(["roadmap", "list", "pi"])

    assert {:error, "invalid list arguments"} =
             Command.parse(["workflow", "list", "--bogus", "x"])
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
      "--priority",
      "3",
      "--dod",
      "done",
      "--sop",
      SopGate.path()
    ]

    assert {:error, "task title is required"} = Command.parse(base)

    assert {:error, "--type must be task or diagnosis"} =
             Command.parse(base ++ ["--type", "shell", "x"])
  end

  test "parses operator lifecycle commands" do
    id = "tsk-20260727T044500Z-1234abcd"

    assert {:ok, {:list_tasks, %{state: "waiting"}}} =
             Command.parse(["task", "list", "--state", "waiting"])

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

    assert {:ok, {:acknowledge_sop, ^id, sop_path}} =
             Command.parse(["task", "acknowledge-sop", id, SopGate.path()])

    assert sop_path == SopGate.path()

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

  test "parses rename and removal commands across entities" do
    assert {:ok, {:rename_project, "pi", "Pi Platform"}} =
             Command.parse(["project", "rename", "pi", "Pi", "Platform"])

    assert {:ok, {:remove_project, "pi"}} = Command.parse(["project", "remove", "pi"])

    assert {:ok, {:rename_roadmap, "pi", "gov", "Governance"}} =
             Command.parse(["roadmap", "rename", "pi", "gov", "Governance"])

    assert {:ok, {:remove_roadmap, "pi", "gov"}} =
             Command.parse(["roadmap", "remove", "pi", "gov"])

    assert {:ok, {:rename_workflow, "pi", "gov", "wf", "Renamed flow"}} =
             Command.parse(["workflow", "rename", "pi", "gov", "wf", "Renamed", "flow"])

    assert {:ok, {:remove_workflow, "pi", "gov", "wf"}} =
             Command.parse(["workflow", "remove", "pi", "gov", "wf"])

    assert {:ok, {:rename_board, "board-id", "Main board"}} =
             Command.parse(["board", "rename", "board-id", "Main", "board"])

    assert {:ok, {:remove_board, "board-id"}} =
             Command.parse(["board", "remove", "board-id"])

    assert {:ok, {:rename_column, "column-id", "In review"}} =
             Command.parse(["column", "rename", "column-id", "In", "review"])

    assert {:ok, {:remove_column, "column-id"}} =
             Command.parse(["column", "remove", "column-id"])

    assert {:ok, {:remove_filter, "filter-id"}} =
             Command.parse(["filter", "remove", "filter-id"])

    id = "tsk-20260727T044500Z-1234abcd"

    assert {:ok, {:remove_todo, ^id, "todo-abc"}} =
             Command.parse(["todo", "remove", id, "todo-abc"])

    # --remove must win over the positional link clause.
    assert {:ok, {:unlink_task, ^id, "evidence", "/tmp/proof"}} =
             Command.parse(["task", "link", id, "--remove", "evidence", "/tmp/proof"])

    assert {:ok, {:link_task, ^id, "evidence", "/tmp/proof"}} =
             Command.parse(["task", "link", id, "evidence", "/tmp/proof"])
  end

  test "rename and removal commands reject missing names and stray arguments" do
    assert {:error, :usage} = Command.parse(["project", "rename", "pi"])
    assert {:error, :usage} = Command.parse(["roadmap", "rename", "pi", "gov"])
    assert {:error, :usage} = Command.parse(["workflow", "rename", "pi", "gov", "wf"])
    assert {:error, :usage} = Command.parse(["board", "rename", "board-id"])
    assert {:error, :usage} = Command.parse(["column", "rename", "column-id"])
    assert {:error, :usage} = Command.parse(["project", "remove"])
    assert {:error, :usage} = Command.parse(["filter", "remove"])
    assert {:error, :usage} = Command.parse(["todo", "remove", "tsk-20260727T044500Z-1234abcd"])
  end

  test "parses dependency authoring commands" do
    id = "tsk-20260727T044500Z-1234abcd"
    predecessor = "tsk-20260727T044500Z-abcd1234"

    assert {:ok, {:list_dependencies, ^id}} = Command.parse(["dep", "list", id])

    assert {:ok, {:add_dependency, ^id, ^predecessor}} =
             Command.parse(["dep", "add", id, "--after", predecessor])

    assert {:ok, {:remove_dependency, ^id, ^predecessor}} =
             Command.parse(["dep", "remove", id, "--after", predecessor])
  end

  test "dependency commands fail closed on malformed arguments" do
    id = "tsk-20260727T044500Z-1234abcd"

    assert {:error, "--after is required"} = Command.parse(["dep", "add", id])
    assert {:error, "--after is required"} = Command.parse(["dep", "remove", id])

    assert {:error, "invalid dependency arguments"} =
             Command.parse(["dep", "add", id, "--after", "x", "stray"])

    assert {:error, "invalid dependency arguments"} =
             Command.parse(["dep", "add", id, "--bogus", "x"])

    assert {:error, :usage} = Command.parse(["dep", "list"])
    assert {:error, :usage} = Command.parse(["dep", "bogus", id])
  end

  test "parses fail-closed inbox capture" do
    assert {:ok, {:add_inbox, "Unclassified operator note"}} =
             Command.parse(["inbox", "add", "Unclassified", "operator", "note"])

    assert {:ok, {:list_inbox, nil}} = Command.parse(["inbox", "list"])
    assert {:error, :usage} = Command.parse(["inbox", "add"])
  end

  test "parses inbox triage commands" do
    assert {:ok, {:list_inbox, "all"}} = Command.parse(["inbox", "list", "--state", "all"])

    assert {:ok, {:list_inbox, "resolved"}} =
             Command.parse(["inbox", "list", "--state", "resolved"])

    assert {:ok, {:resolve_inbox, "inbox-abc", nil}} =
             Command.parse(["inbox", "done", "inbox-abc"])

    assert {:ok, {:drop_inbox, "inbox-abc", "not actionable"}} =
             Command.parse(["inbox", "drop", "inbox-abc", "not", "actionable"])

    assert {:ok, {:promote_inbox, "inbox-abc", promoted}} =
             Command.parse([
               "inbox",
               "promote",
               "inbox-abc",
               "--project",
               "pi",
               "--roadmap",
               "buzz-agent-collaboration-plane",
               "--workflow",
               "buzz-integration",
               "--priority",
               "2",
               "--dod",
               "triage closes",
               "--sop",
               SopGate.path()
             ])

    assert promoted.project == "pi"
    assert promoted.priority == 2
    assert promoted.definition_of_done == "triage closes"
    assert promoted.task_type == :task
    assert promoted.title == nil

    assert {:ok, {:promote_inbox, "inbox-abc", %{title: "Explicit title", task_type: :diagnosis}}} =
             Command.parse([
               "inbox",
               "promote",
               "inbox-abc",
               "--project",
               "pi",
               "--roadmap",
               "r",
               "--workflow",
               "w",
               "--priority",
               "4",
               "--dod",
               "d",
               "--sop",
               SopGate.path(),
               "--type",
               "diagnosis",
               "--title",
               "Explicit title"
             ])
  end

  test "inbox triage commands fail closed on malformed arguments" do
    assert {:error, :usage} = Command.parse(["inbox", "done"])
    assert {:error, :usage} = Command.parse(["inbox", "drop", "inbox-abc"])
    assert {:error, "invalid list arguments"} = Command.parse(["inbox", "list", "stray"])

    base = [
      "inbox",
      "promote",
      "inbox-abc",
      "--project",
      "pi",
      "--roadmap",
      "r",
      "--workflow",
      "w",
      "--priority",
      "3",
      "--dod",
      "d",
      "--sop",
      SopGate.path()
    ]

    assert {:error, "--type must be task or diagnosis"} =
             Command.parse(base ++ ["--type", "shell"])

    assert {:error, "invalid inbox promote arguments"} = Command.parse(base ++ ["stray"])

    assert {:error, "--priority must be between 0 and 5"} =
             Command.parse(replace_option(base, "--priority", "6"))

    for missing <- ["project", "roadmap", "workflow", "priority", "dod", "sop"] do
      assert {:error, _} = Command.parse(drop_option(base, "--#{missing}"))
    end
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

  defp replace_option(args, option, value) do
    {left, [_option, _current | right]} = Enum.split_while(args, &(&1 != option))
    left ++ [option, value | right]
  end
end
