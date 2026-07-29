defmodule SpruceGoose.CLIDatabaseTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.SopGate
  alias SpruceGoose.Workflows.{Definition, Dependency, Project, Roadmap, Task, Workflow}

  test "CLI admits a complete project roadmap workflow DAG task TODO hierarchy" do
    assert {:ok, %{key: "dogfood"} = project} =
             Executor.run({:add_project, "dogfood", "Dogfood"})

    assert {:ok, %{id: roadmap_id, key: "dev", project_id: project_id}} =
             Executor.run({:add_roadmap, "dogfood", "dev", "Development"})

    assert project_id == project.id

    definition =
      ~s({"schema_version":1,"tasks":[{"id":"verify","kind":"oban","depends_on":["build"]},{"id":"build","kind":"oban"}]})

    assert {:ok,
            %{
              id: workflow_id,
              workflow_id: "proof",
              roadmap_id: workflow_roadmap_id,
              definition: %{schema_version: 1, tasks: output_tasks}
            }} =
             Executor.run({
               :add_workflow,
               "dogfood",
               "dev",
               "proof",
               "Proof workflow",
               definition
             })

    assert workflow_roadmap_id == roadmap_id
    assert Jason.encode!(output_tasks)
    assert {:ok, workflow} = Ash.get(Workflow, workflow_id)
    assert Enum.map(workflow.definition.tasks, & &1.id) == ["verify", "build"]

    assert {:ok, task} =
             Executor.run({
               :add_task,
               %{
                 project: "dogfood",
                 roadmap: "dev",
                 workflow: "proof",
                 task_type: :task,
                 title: "Exercise the hierarchy",
                 definition_of_done: "TODO is complete",
                 sop_path: SopGate.path()
               }
             })

    assert {:ok, todo} = Executor.run({:add_todo, task.id, "Capture proof"})
    assert {:ok, %{completed: true}} = Executor.run({:complete_todo, task.id, todo.id})
  end

  test "hierarchy read commands list, scope, and fail closed on unknown keys" do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "build", kind: :oban}]})

    {:ok, alpha} = Ash.create(Project, %{key: "alpha", name: "Alpha"})
    {:ok, beta} = Ash.create(Project, %{key: "beta", name: "Beta"})

    {:ok, alpha_one} =
      Ash.create(Roadmap, %{project_id: alpha.id, key: "one", name: "Alpha One"})

    {:ok, _alpha_two} =
      Ash.create(Roadmap, %{project_id: alpha.id, key: "two", name: "Alpha Two"})

    {:ok, beta_one} =
      Ash.create(Roadmap, %{project_id: beta.id, key: "solo", name: "Beta Solo"})

    {:ok, _} =
      Ash.create(Workflow, %{
        roadmap_id: alpha_one.id,
        workflow_id: "alpha-flow",
        name: "Alpha flow",
        definition: definition
      })

    {:ok, _} =
      Ash.create(Workflow, %{
        roadmap_id: beta_one.id,
        workflow_id: "beta-flow",
        name: "Beta flow",
        definition: definition
      })

    assert {:ok, %{projects: projects}} = Executor.run(:list_projects)
    keys = Enum.map(projects, & &1.key)
    assert "alpha" in keys
    assert "beta" in keys
    assert keys == Enum.sort(keys)

    assert {:ok, %{key: "alpha", name: "Alpha"}} = Executor.run({:show_project, "alpha"})

    assert {:ok, %{roadmaps: scoped}} = Executor.run({:list_roadmaps, "alpha"})
    assert Enum.map(scoped, & &1.key) == ["one", "two"]
    assert Enum.all?(scoped, &(&1.project == "alpha"))

    assert {:ok, %{roadmaps: all_roadmaps}} = Executor.run({:list_roadmaps, nil})
    assert length(all_roadmaps) >= 3

    assert {:ok, %{key: "one", project: "alpha"}} =
             Executor.run({:show_roadmap, "alpha", "one"})

    assert {:ok, %{workflows: alpha_workflows}} = Executor.run({:list_workflows, "alpha", nil})
    assert Enum.map(alpha_workflows, & &1.workflow_id) == ["alpha-flow"]
    assert Enum.all?(alpha_workflows, &(&1.roadmap == "alpha/one"))

    assert {:ok, %{workflows: by_roadmap}} = Executor.run({:list_workflows, nil, "solo"})
    assert Enum.map(by_roadmap, & &1.workflow_id) == ["beta-flow"]

    assert {:ok, %{workflows: narrowed}} = Executor.run({:list_workflows, "alpha", "one"})
    assert Enum.map(narrowed, & &1.workflow_id) == ["alpha-flow"]

    assert {:ok, %{workflows: []}} = Executor.run({:list_workflows, "alpha", "two"})

    assert {:ok, shown} = Executor.run({:show_workflow, "alpha", "one", "alpha-flow"})
    assert shown.project == "alpha"
    assert shown.roadmap == "one"
    assert Enum.map(shown.definition.tasks, & &1.id) == ["build"]

    assert {:error, "not found"} = Executor.run({:show_project, "missing"})
    assert {:error, "not found"} = Executor.run({:list_roadmaps, "missing"})
    assert {:error, "not found"} = Executor.run({:show_roadmap, "alpha", "missing"})
    assert {:error, "not found"} = Executor.run({:list_workflows, "missing", nil})
    assert {:error, "not found"} = Executor.run({:list_workflows, nil, "missing"})
    assert {:error, "not found"} = Executor.run({:show_workflow, "alpha", "one", "missing"})
    assert {:error, "not found"} = Executor.run({:show_workflow, "beta", "one", "alpha-flow"})
  end

  test "hierarchy reads expose keys sufficient to admit a governed task" do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "admit", kind: :oban}]})
    {:ok, project} = Ash.create(Project, %{key: "discover", name: "Discover"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{project_id: project.id, key: "paths", name: "Paths"})

    {:ok, _} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "admission",
        name: "Admission",
        definition: definition
      })

    {:ok, %{projects: projects}} = Executor.run(:list_projects)
    project_key = Enum.find(projects, &(&1.key == "discover")).key

    {:ok, %{roadmaps: roadmaps}} = Executor.run({:list_roadmaps, project_key})
    roadmap_key = hd(roadmaps).key

    {:ok, %{workflows: workflows}} = Executor.run({:list_workflows, project_key, roadmap_key})
    workflow_key = hd(workflows).workflow_id

    assert {:ok, task} =
             Executor.run({
               :add_task,
               %{
                 project: project_key,
                 roadmap: roadmap_key,
                 workflow: workflow_key,
                 task_type: :task,
                 title: "Admitted from discovered keys",
                 definition_of_done: "Discovery closes the admission loop",
                 sop_path: SopGate.path()
               }
             })

    assert task.title == "Admitted from discovered keys"
  end

  test "CLI task admission writes to PostgreSQL and show reads it back" do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "admit", kind: :oban}]})
    {:ok, project} = Ash.create(Project, %{key: "pi", name: "Pi"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{
        project_id: project.id,
        key: "sprucegoose",
        name: "SpruceGoose"
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
                 roadmap: "sprucegoose",
                 workflow: "audit-fixes",
                 task_type: :task,
                 title: "Persist through CLI",
                 definition_of_done: "The record is readable",
                 sop_path: SopGate.path()
               }
             })

    assert created.title == "Persist through CLI"
    assert created.sop_gate_required
    assert created.sop_path == SopGate.path()
    assert created.sop_digest =~ ~r/^[0-9a-f]{64}$/
    assert created.sop_acknowledged_at
    assert {:ok, shown} = Executor.run({:show_task, created.id})
    assert shown == created
  end

  test "start rejects stale SOP acknowledgment and accepts a refreshed acknowledgment" do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "gate", kind: :openclaw}]})
    {:ok, project} = Ash.create(Project, %{key: "sop-gate", name: "SOP gate"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{project_id: project.id, key: "admission", name: "Admission"})

    {:ok, _workflow} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "verify",
        name: "Verify",
        definition: definition
      })

    {:ok, task} =
      Executor.run({
        :add_task,
        %{
          project: "sop-gate",
          roadmap: "admission",
          workflow: "verify",
          task_type: :task,
          title: "Require current SOP",
          definition_of_done: "Start is gated",
          sop_path: SopGate.path()
        }
      })

    for target <- [:proposed, :queued, :ready] do
      assert {:ok, %{state: ^target}} =
               Executor.run({:transition_task, task.id, target, nil})
    end

    Ecto.Adapters.SQL.query!(
      SpruceGoose.Repo,
      "UPDATE workflow_tasks SET sop_digest = repeat('0', 64) WHERE task_id = $1",
      [task.id]
    )

    assert {:error, "Systemwide SOP acknowledgment is stale; run task acknowledge-sop"} =
             Executor.run({:transition_task, task.id, :in_progress, nil})

    assert {:ok, refreshed} = Executor.run({:acknowledge_sop, task.id, SopGate.path()})
    refute refreshed.sop_digest == String.duplicate("0", 64)

    assert {:ok, %{state: :in_progress}} =
             Executor.run({:transition_task, task.id, :in_progress, nil})
  end

  test "direct Ash start enforces the current SOP acknowledgment" do
    task = gated_task("direct-start")

    task =
      Enum.reduce([:proposed, :queued, :ready], task, fn state, current ->
        assert {:ok, current} = Ash.update(current, %{to_state: state}, action: :transition)
        current
      end)

    Ecto.Adapters.SQL.query!(
      SpruceGoose.Repo,
      "UPDATE workflow_tasks SET sop_digest = repeat('0', 64) WHERE id = $1::text::uuid",
      [task.id]
    )

    task = Ash.get!(Task, task.id)
    assert {:error, error} = Ash.update(task, %{to_state: :in_progress}, action: :transition)
    assert Exception.message(error) =~ "Systemwide SOP acknowledgment is stale"

    assert {:error, error} = Ash.update(task, %{to_state: :in_progress}, action: :move)
    assert Exception.message(error) =~ "Systemwide SOP acknowledgment is stale"
  end

  test "ordinary Task callers cannot choose exemptions or manufacture SOP evidence" do
    workflow = workflow("caller-evidence")

    assert {:error, error} =
             Ash.create(Task, %{
               workflow_id: workflow.id,
               task_id: "tsk-20260728T142900Z-acde1234",
               title: "Manufacture evidence",
               definition_of_done: "Rejected",
               runner: :oban,
               sop_gate_required: false,
               sop_digest: String.duplicate("0", 64),
               sop_acknowledged_at: DateTime.utc_now()
             })

    message = Exception.message(error)
    assert message =~ "sop_gate_required"
    assert message =~ "sop_digest"

    task = gated_task("caller-acknowledgment")

    assert {:error, error} =
             Ash.update(task, %{sop_digest: String.duplicate("0", 64)}, action: :acknowledge_sop)

    assert Exception.message(error) =~ "sop_digest"
  end

  test "SOP path is runtime-configurable while evidence retains a stable identifier" do
    original = Application.fetch_env!(:spruce_goose, :systemwide_sop_path)
    alternate = Path.join(System.tmp_dir!(), "sprucegoose-systemwide-sop.md")
    File.write!(alternate, "# Alternate Systemwide SOP\n")
    Application.put_env(:spruce_goose, :systemwide_sop_path, alternate)

    on_exit(fn ->
      Application.put_env(:spruce_goose, :systemwide_sop_path, original)
      File.rm(alternate)
    end)

    task = gated_task("alternate-path")
    assert task.sop_id == "systemwide-sop"
    assert task.sop_path == alternate
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

  defp gated_task(suffix) do
    workflow = workflow(suffix)

    {:ok, task} =
      Ash.create(Task, %{
        workflow_id: workflow.id,
        task_id:
          "tsk-20260728T143000Z-#{String.slice(:crypto.hash(:sha256, suffix) |> Base.encode16(case: :lower), 0, 8)}",
        title: "Task #{suffix}",
        definition_of_done: "SOP gate is enforced",
        runner: :oban
      })

    task
  end

  defp workflow(suffix) do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "task-#{suffix}", kind: :oban}]})
    {:ok, project} = Ash.create(Project, %{key: "project-#{suffix}", name: "Project #{suffix}"})

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
        definition: definition
      })

    workflow
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
