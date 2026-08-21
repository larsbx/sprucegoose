defmodule SpruceGoose.CLITest do
  use ExUnit.Case, async: true

  alias SpruceGoose.CLI
  alias SpruceGoose.CLI.Command
  alias SpruceGoose.SopGate
  alias SpruceGoose.TaskId

  test "returns scoped help for every command family and rejects unknown families" do
    families =
      ~w(id project blueprint roadmap workflow task dep todo board column filter inbox ledger outbox derivation)

    for family <- families, help_arg <- ["help", "--help"] do
      assert {:ok, help} = CLI.run([family, help_arg])
      assert help.command == family
      assert help.usage == "sprucegoose #{family} <command> [args]"
      assert help.forms != []
    end

    assert {:ok, task_help} = CLI.run(["task", "--help"])

    refute Enum.any?(task_help.forms, &String.starts_with?(&1, "add "))

    assert "instantiate --project KEY --roadmap KEY --workflow ID --blueprint REVISION --definition KEY --priority N [--type task|diagnosis]" in task_help.forms

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

  test "parses typed derivation admission and inspection" do
    digest = String.duplicate("d", 64)

    assert {:ok, {:admit_derivation, attrs}} =
             Command.parse([
               "derivation",
               "admit",
               "--task",
               "tsk-20260821T120000Z-1234abcd",
               "--source-event",
               "forgejo:delivery-1",
               "--forge-instance",
               "mama-forgejo",
               "--repository",
               "root/sprucegoose",
               "--commit",
               String.duplicate("a", 40),
               "--tree",
               String.duplicate("b", 40),
               "--ref",
               "refs/heads/staging",
               "--pipeline-digest",
               String.duplicate("c", 64),
               "--action",
               "verify_artifact",
               "--input-artifact",
               digest
             ])

    assert attrs.action == :verify_artifact
    assert attrs.input_artifact_digest == digest

    assert {:ok, {:show_derivation, "drv-abc"}} =
             Command.parse(["derivation", "show", "drv-abc"])

    assert {:error, "invalid derivation admit arguments"} =
             Command.parse(["derivation", "admit", "--action", "shell"])
  end

  test "unbound task add is retired from the public command surface" do
    assert {:error, message} = Command.parse(["task", "add", "Legacy task"])
    assert message =~ "retired"
    assert message =~ "task instantiate"
  end

  test "task instantiation requires an exact blueprint and definition key" do
    assert {:ok, {:instantiate_task, task}} =
             Command.parse([
               "task",
               "instantiate",
               "--project",
               "pi",
               "--roadmap",
               "delivery",
               "--workflow",
               "release-v1",
               "--blueprint",
               "bpr-abc",
               "--definition",
               "test",
               "--priority",
               "1"
             ])

    assert task.blueprint == "bpr-abc"
    assert task.definition == "test"
    assert task.priority == 1
    assert task.task_type == :task

    assert {:error, "--definition is required"} =
             Command.parse([
               "task",
               "instantiate",
               "--project",
               "pi",
               "--roadmap",
               "delivery",
               "--workflow",
               "release-v1",
               "--blueprint",
               "bpr-abc",
               "--priority",
               "1"
             ])
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
    assert {:ok, {:view_project, "pi"}} = Command.parse(["project", "view", "pi"])

    assert {:ok, {:register_blueprint, "pi", "root/pi", "commit", ".sprucegoose/project.yaml"}} =
             Command.parse([
               "blueprint",
               "register",
               "pi",
               "root/pi",
               "commit",
               ".sprucegoose/project.yaml"
             ])

    assert {:ok, {:apply_blueprint, "pi", "root/pi", "commit", ".sprucegoose/project.yaml"}} =
             Command.parse([
               "blueprint",
               "apply",
               "pi",
               "root/pi",
               "commit",
               ".sprucegoose/project.yaml"
             ])

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

  test "parses dependency graph query commands" do
    task_id = "tsk-20260810T142243Z-66915779"

    assert {:ok, {:task_blockers, ^task_id}} =
             Command.parse(["task", "blockers", task_id])

    assert {:ok, {:task_impact, ^task_id}} =
             Command.parse(["task", "impact", task_id])

    assert {:ok, {:workflow_critical_path, "openclaw-system", "convergence", "v1"}} =
             Command.parse([
               "workflow",
               "critical-path",
               "openclaw-system",
               "convergence",
               "v1"
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

  test "retired task add refuses every legacy argument shape" do
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

    for args <- [base, base ++ ["--type", "shell", "x"]] do
      assert {:error, message} = Command.parse(args)
      assert message =~ "task add is retired"
      assert message =~ "task instantiate"
    end
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

    assert {:ok, {:record_artifact_receipt, ^id, "prototype", "/tmp/prototype", "telegram:6680"}} =
             Command.parse([
               "task",
               "artifact-receipt",
               id,
               "prototype",
               "/tmp/prototype",
               "telegram:6680"
             ])

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

    assert {:error, message} = Command.parse(["inbox", "promote", "inbox-abc"])
    assert message =~ "retired"
    assert message =~ "task instantiate"
  end

  test "inbox triage commands fail closed on malformed arguments" do
    assert {:error, :usage} = Command.parse(["inbox", "done"])
    assert {:error, :usage} = Command.parse(["inbox", "drop", "inbox-abc"])
    assert {:error, "invalid list arguments"} = Command.parse(["inbox", "list", "stray"])

    assert {:error, message} = Command.parse(["inbox", "promote", "inbox-abc", "stray"])
    assert message =~ "retired"
  end

  test "parses subordinate TODO commands" do
    id = "tsk-20260727T044500Z-1234abcd"

    assert {:ok, {:add_todo, ^id, "Attach evidence"}} =
             Command.parse(["todo", "add", id, "Attach", "evidence"])

    assert {:ok, {:list_todos, ^id}} = Command.parse(["todo", "list", id])

    assert {:ok, {:complete_todo, ^id, "todo-abc"}} =
             Command.parse(["todo", "done", id, "todo-abc"])
  end
end
