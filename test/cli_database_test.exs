defmodule SpruceGoose.CLIDatabaseTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.SopGate
  alias SpruceGoose.Actors.{Actor, Grant}

  alias SpruceGoose.Workflows.{
    Board,
    BoardColumn,
    BlueprintRevision,
    Definition,
    Dependency,
    Project,
    Roadmap,
    Task,
    Workflow
  }

  test "blueprint apply creates a repository-defined project atomically" do
    previous = Application.get_env(:spruce_goose, :blueprint_source_verifier)
    Application.put_env(:spruce_goose, :blueprint_source_verifier, __MODULE__.NewProjectVerifier)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spruce_goose, :blueprint_source_verifier, previous),
        else: Application.delete_env(:spruce_goose, :blueprint_source_verifier)
    end)

    actor =
      Ash.create!(Actor, %{name: "new-project-approver", kind: :agent, created_by: "test"},
        authorize?: false
      )

    Ash.create!(
      Grant,
      %{actor_id: actor.id, role: :approver, scope: "*", granted_by: "test"},
      authorize?: false
    )

    assert {:error, register_error} =
             Executor.run(
               {:register_blueprint, "new-project", "root/new-project", String.duplicate("a", 40),
                ".sprucegoose/project.yaml"},
               actor.name
             )

    assert register_error =~ "use blueprint apply to create it"
    assert Ash.read!(Ash.Query.filter_input(Project, key: "new-project")) == []

    assert {:ok, %{project: "new-project", action: :apply}} =
             Executor.run(
               {:apply_blueprint, "new-project", "root/new-project", String.duplicate("a", 40),
                ".sprucegoose/project.yaml"},
               actor.name
             )

    project = Ash.read_one!(Ash.Query.filter_input(Project, key: "new-project"))
    assert project.name == "New Project"
    assert [_] = Ash.read!(Ash.Query.filter_input(Roadmap, project_id: project.id))
    assert [_] = Ash.read!(Ash.Query.filter_input(BlueprintRevision, project_id: project.id))
  end

  test "a rejected new-project blueprint leaves no constitutive rows" do
    previous = Application.get_env(:spruce_goose, :blueprint_source_verifier)

    Application.put_env(
      :spruce_goose,
      :blueprint_source_verifier,
      __MODULE__.InvalidNewProjectVerifier
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spruce_goose, :blueprint_source_verifier, previous),
        else: Application.delete_env(:spruce_goose, :blueprint_source_verifier)
    end)

    actor =
      Ash.create!(Actor, %{name: "invalid-project-approver", kind: :agent, created_by: "test"},
        authorize?: false
      )

    Ash.create!(
      Grant,
      %{actor_id: actor.id, role: :approver, scope: "*", granted_by: "test"},
      authorize?: false
    )

    assert {:error, error} =
             Executor.run(
               {:apply_blueprint, "invalid-project", "root/invalid-project",
                String.duplicate("a", 40), ".sprucegoose/project.yaml"},
               actor.name
             )

    assert inspect(error) =~ "depends on unknown task"
    assert Ash.read!(Ash.Query.filter_input(Project, key: "invalid-project")) == []
    assert Ash.read!(BlueprintRevision) == []
  end

  defmodule NewProjectVerifier do
    @behaviour SpruceGoose.Blueprints.SourceVerifier

    @impl true
    def verify(_repository, _commit, _path) do
      bytes = """
      schema_version: 1
      project:
        key: new-project
        name: New Project
      roadmaps:
        - key: delivery
          name: Delivery
          workflows:
            - id: release-v1
              name: Release v1
              definition:
                schema_version: 1
                tasks:
                  - id: verify
                    kind: oban
                    title: Verify
                    definition_of_done: Verification passes
                    depends_on: []
                    input: {}
      """

      {:ok,
       %{
         tree: String.duplicate("b", 40),
         digest: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
         bytes: bytes
       }}
    end
  end

  defmodule InvalidNewProjectVerifier do
    @behaviour SpruceGoose.Blueprints.SourceVerifier

    @impl true
    def verify(_repository, _commit, _path) do
      bytes = """
      schema_version: 1
      project:
        key: invalid-project
        name: Invalid Project
      roadmaps:
        - key: delivery
          name: Delivery
          workflows:
            - id: release-v1
              name: Release v1
              definition:
                schema_version: 1
                tasks:
                  - id: verify
                    kind: oban
                    title: Verify
                    definition_of_done: Verification passes
                    depends_on: [missing]
                    input: {}
      """

      {:ok,
       %{
         tree: String.duplicate("b", 40),
         digest: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
         bytes: bytes
       }}
    end
  end

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
                 priority: 3,
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
                 priority: 3,
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
                 priority: 2,
                 task_type: :task,
                 title: "Persist through CLI",
                 definition_of_done: "The record is readable",
                 sop_path: SopGate.path()
               }
             })

    assert created.title == "Persist through CLI"
    assert created.priority == 2
    assert created.sop_gate_required
    assert created.sop_path == SopGate.path()
    assert created.sop_digest =~ ~r/^[0-9a-f]{64}$/
    assert created.sop_acknowledged_at
    assert created.project == "pi"
    assert created.roadmap == "sprucegoose"
    assert created.workflow == "audit-fixes"
    assert created.workflow_name == "Audit fixes"
    assert {:ok, shown} = Executor.run({:show_task, created.id})
    assert shown == created
  end

  test "executor rejects absent and invalid task priority before admission" do
    assert {:error, "priority is required"} = Executor.run({:add_task, %{}})

    assert {:error, "priority must be between 0 and 5"} =
             Executor.run({:add_task, %{priority: 6}})
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
          priority: 1,
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

  test "artifact-dependent tasks fail closed at ready until a verified receipt is recorded" do
    workflow = workflow("artifact-receipt")

    {:ok, task} =
      Ash.create(Task, %{
        workflow_id: workflow.id,
        task_id: "tsk-20260810T121900Z-acde1234",
        title: "Consume prototype",
        definition_of_done: "Prototype is processed",
        runner: :openclaw,
        artifact_requirements: ["prototype"]
      })

    task =
      Enum.reduce([:proposed, :queued], task, fn target, current ->
        assert {:ok, updated} = Ash.update(current, %{to_state: target}, action: :transition)
        updated
      end)

    assert {:error, error} = Ash.update(task, %{to_state: :ready}, action: :transition)
    assert Exception.message(error) =~ "missing verified receipts for: prototype"

    assert {:error, %Postgrex.Error{postgres: %{message: message}}} =
             Ecto.Adapters.SQL.query(
               SpruceGoose.Repo,
               "UPDATE workflow_tasks SET state = 'ready' WHERE id = $1::text::uuid",
               [task.id],
               mode: :savepoint
             )

    assert message =~ "missing verified artifact receipt"

    source = Path.join(System.tmp_dir!(), "sprucegoose-artifact-source")
    File.write!(source, "prototype bytes")
    on_exit(fn -> File.rm(source) end)

    assert {:error, "artifact verifier must not also hold operator over the task"} =
             Executor.run({
               :record_artifact_receipt,
               task.task_id,
               "prototype",
               source,
               "telegram:message:6680"
             })

    {:ok, verifier} =
      Ash.create(
        SpruceGoose.Actors.Actor,
        %{name: "receipt-verifier", kind: :agent, created_by: "test"},
        authorize?: false
      )

    {:ok, _grant} =
      Ash.create(
        SpruceGoose.Actors.Grant,
        %{actor_id: verifier.id, role: :artifact_verifier, scope: "*", granted_by: "test"},
        authorize?: false
      )

    assert {:ok, received} =
             Executor.run(
               {:record_artifact_receipt, task.task_id, "prototype", source,
                "telegram:message:6680"},
               "receipt-verifier"
             )

    assert [receipt] = received.artifact_receipts

    assert receipt["sha256"] ==
             :crypto.hash(:sha256, "prototype bytes") |> Base.encode16(case: :lower)

    assert receipt["storage_locator"] == "cas:sha256:" <> receipt["sha256"]
    assert receipt["retrieval_verifier"] == "receipt-verifier"
    assert receipt["size_bytes"] == 15

    invalid =
      receipt
      |> Map.put("size_bytes", 0)
      |> Map.put("extra", true)
      |> Map.put("retrieval_verified_at", "2999-01-01T00:00:00Z")

    assert {:error, error} =
             Ash.update(task, %{artifact_receipts: [invalid]}, action: :record_artifact_receipt)

    assert Exception.message(error) =~ "verified immutable receipt fields"
    task = Ash.get!(Task, task.id)
    assert {:ok, ready} = Ash.update(task, %{to_state: :ready}, action: :transition)

    assert {:error, error} =
             Ash.update(ready, %{artifact_receipts: [receipt]}, action: :record_artifact_receipt)

    assert Exception.message(error) =~ "immutable after readiness"
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

    assert {:ok, %{tasks: [%{id: id, state: :waiting}]}} =
             Executor.run({:list_tasks, %{state: "waiting"}})

    assert id == task.task_id

    for target <- [:ready, :in_progress, :completed] do
      assert {:ok, %{state: ^target}} =
               Executor.run({:transition_task, task.task_id, target, nil})
    end

    assert {:ok, %{state: :in_progress}} =
             Executor.run({:transition_task, successor.task_id, :in_progress, nil})

    assert {:ok, todo} = Executor.run({:add_todo, successor.task_id, "Attach evidence"})

    # Identical checklist text is a second distinct TODO, not a silent no-op.
    assert {:ok, duplicate} = Executor.run({:add_todo, successor.task_id, "Attach evidence"})
    assert duplicate.id != todo.id
    assert [todo.position, duplicate.position] == [1, 2]

    assert {:ok, %{todos: [^todo, ^duplicate]}} =
             Executor.run({:list_todos, successor.task_id})

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

  test "rename updates names across the hierarchy without touching keys" do
    workflow = workflow("rename")

    assert {:ok, %{key: "project-rename", name: "Renamed project"}} =
             Executor.run({:rename_project, "project-rename", "Renamed project"})

    assert {:ok, %{key: "roadmap-rename", name: "Renamed roadmap"}} =
             Executor.run(
               {:rename_roadmap, "project-rename", "roadmap-rename", "Renamed roadmap"}
             )

    assert {:ok, %{workflow_id: "workflow-rename", name: "Renamed workflow"}} =
             Executor.run(
               {:rename_workflow, "project-rename", "roadmap-rename", "workflow-rename",
                "Renamed workflow"}
             )

    {:ok, board} = Ash.create(Board, %{workflow_id: workflow.id, key: "b", name: "Board"})

    assert {:ok, %{name: "Renamed board"}} =
             Executor.run({:rename_board, board.id, "Renamed board"})

    {:ok, column} =
      Ash.create(BoardColumn, %{
        board_id: board.id,
        key: "ready",
        name: "Ready",
        position: 1,
        task_state: :ready
      })

    assert {:ok, %{name: "Renamed column", key: "ready"}} =
             Executor.run({:rename_column, column.id, "Renamed column"})

    assert {:error, "not found"} =
             Executor.run({:rename_project, "missing", "Nope"})
  end

  test "removal refuses while dependents exist and succeeds once they are gone" do
    workflow = workflow("removal")

    assert {:error, "cannot remove while 1 roadmaps still reference it"} =
             Executor.run({:remove_project, "project-removal"})

    assert {:error, "cannot remove while 1 workflows still reference it"} =
             Executor.run({:remove_roadmap, "project-removal", "roadmap-removal"})

    {:ok, board} = Ash.create(Board, %{workflow_id: workflow.id, key: "b", name: "Board"})

    assert {:error, "cannot remove while 1 boards still reference it"} =
             Executor.run(
               {:remove_workflow, "project-removal", "roadmap-removal", "workflow-removal"}
             )

    {:ok, column} =
      Ash.create(BoardColumn, %{
        board_id: board.id,
        key: "ready",
        name: "Ready",
        position: 1,
        task_state: :ready
      })

    assert {:error, "cannot remove while 1 columns still reference it"} =
             Executor.run({:remove_board, board.id})

    assert {:ok, %{removed: %{key: "ready"}}} = Executor.run({:remove_column, column.id})
    assert {:ok, %{removed: %{key: "b"}}} = Executor.run({:remove_board, board.id})

    assert {:ok, %{removed: %{workflow_id: "workflow-removal"}}} =
             Executor.run(
               {:remove_workflow, "project-removal", "roadmap-removal", "workflow-removal"}
             )

    assert {:ok, %{removed: %{key: "roadmap-removal"}}} =
             Executor.run({:remove_roadmap, "project-removal", "roadmap-removal"})

    assert {:ok, %{removed: %{key: "project-removal"}}} =
             Executor.run({:remove_project, "project-removal"})

    assert {:error, "not found"} = Executor.run({:show_project, "project-removal"})
    assert {:error, "not found"} = Executor.run({:remove_project, "project-removal"})
  end

  test "workflow removal refuses while tasks reference it" do
    workflow = workflow("task-guard")
    _task = dependency_task(workflow, "guard")

    assert {:error, "cannot remove while 1 tasks still reference it"} =
             Executor.run(
               {:remove_workflow, "project-task-guard", "roadmap-task-guard",
                "workflow-task-guard"}
             )
  end

  test "todo removal clears checklist items and refuses on terminal tasks" do
    workflow = workflow("todo-removal")
    task = dependency_task(workflow, "todo-host")

    {:ok, todo} = Executor.run({:add_todo, task.task_id, "Remove me"})
    {:ok, kept} = Executor.run({:add_todo, task.task_id, "Keep me"})

    assert {:ok, %{removed: %{id: removed_id}}} =
             Executor.run({:remove_todo, task.task_id, todo.id})

    assert removed_id == todo.id

    assert {:ok, %{todos: [remaining]}} = Executor.run({:list_todos, task.task_id})
    assert remaining.id == kept.id

    assert {:error, "not found"} = Executor.run({:remove_todo, task.task_id, todo.id})

    for target <- [:proposed, :queued, :ready, :in_progress] do
      {:ok, _} = Executor.run({:transition_task, task.task_id, target, nil})
    end

    {:ok, _} = Executor.run({:complete_todo, task.task_id, kept.id})
    {:ok, _} = Executor.run({:transition_task, task.task_id, :completed, nil})

    assert {:error, "cannot add TODO to terminal task"} =
             Executor.run({:remove_todo, task.task_id, kept.id})
  end

  test "task link --remove clears a single reference and leaves the rest intact" do
    workflow = workflow("unlink")
    task = dependency_task(workflow, "unlink-host")

    {:ok, _} = Executor.run({:link_task, task.task_id, "repo", "sprucegoose@abc123"})
    {:ok, linked} = Executor.run({:link_task, task.task_id, "evidence", "/tmp/proof"})

    assert length(linked.references) == 2

    assert {:ok, unlinked} =
             Executor.run({:unlink_task, task.task_id, "evidence", "/tmp/proof"})

    assert unlinked.references == [%{"kind" => "repo", "value" => "sprucegoose@abc123"}]

    assert {:error, "reference not found"} =
             Executor.run({:unlink_task, task.task_id, "evidence", "/tmp/proof"})

    assert {:error, "invalid task ID"} =
             Executor.run({:unlink_task, "nonsense", "repo", "x"})
  end

  test "filter removal clears saved filters" do
    workflow = workflow("filter-removal")
    {:ok, board} = Ash.create(Board, %{workflow_id: workflow.id, key: "b", name: "Board"})

    {:ok, filter} =
      Executor.run({:add_filter, board.id, "mine", ~s({"state":"ready"})})

    assert {:ok, %{filters: [_]}} = Executor.run({:list_filters, board.id})
    assert {:ok, %{removed: %{name: "mine"}}} = Executor.run({:remove_filter, filter.id})
    assert {:ok, %{filters: []}} = Executor.run({:list_filters, board.id})
    assert {:error, "not found"} = Executor.run({:remove_filter, filter.id})
  end

  test "dependency authoring creates, lists, and clears runtime task edges" do
    workflow = workflow("deps")
    upstream = dependency_task(workflow, "upstream")
    downstream = dependency_task(workflow, "downstream")

    assert {:ok, edge} =
             Executor.run({:add_dependency, downstream.task_id, upstream.task_id})

    assert edge.task == downstream.task_id
    assert edge.depends_on == upstream.task_id
    assert edge.source == "native"

    assert {:ok, listed} = Executor.run({:list_dependencies, downstream.task_id})
    assert listed.blocked
    assert [%{task: predecessor_id, state: :inbox}] = listed.predecessors
    assert predecessor_id == upstream.task_id
    assert listed.successors == []

    assert {:ok, upstream_view} = Executor.run({:list_dependencies, upstream.task_id})
    refute upstream_view.blocked
    assert [%{task: successor_id}] = upstream_view.successors
    assert successor_id == downstream.task_id

    assert {:ok, removed} =
             Executor.run({:remove_dependency, downstream.task_id, upstream.task_id})

    assert removed.removed == edge.id

    assert {:ok, %{predecessors: [], blocked: false}} =
             Executor.run({:list_dependencies, downstream.task_id})

    assert {:error, "not found"} =
             Executor.run({:remove_dependency, downstream.task_id, upstream.task_id})
  end

  test "dependency admission rejects cycles, duplicates, self edges, and cross-workflow links" do
    workflow = workflow("cycles")
    a = dependency_task(workflow, "a")
    b = dependency_task(workflow, "b")
    c = dependency_task(workflow, "c")

    assert {:error, "a task cannot depend on itself"} =
             Executor.run({:add_dependency, a.task_id, a.task_id})

    assert {:ok, _} = Executor.run({:add_dependency, b.task_id, a.task_id})

    assert {:error, "dependency already exists"} =
             Executor.run({:add_dependency, b.task_id, a.task_id})

    assert {:error, "dependency would create a cycle"} =
             Executor.run({:add_dependency, a.task_id, b.task_id})

    # Multi-hop: a -> b -> c, so c -> a would close a three-node cycle.
    assert {:ok, _} = Executor.run({:add_dependency, c.task_id, b.task_id})

    assert {:error, "dependency would create a cycle"} =
             Executor.run({:add_dependency, a.task_id, c.task_id})

    # Clearing the middle edge re-legalises the previously cyclic edge.
    assert {:ok, _} = Executor.run({:remove_dependency, c.task_id, b.task_id})
    assert {:ok, _} = Executor.run({:add_dependency, a.task_id, c.task_id})

    other = workflow("cycles-other")
    foreign = dependency_task(other, "foreign")

    assert {:error, "dependencies must stay within one workflow"} =
             Executor.run({:add_dependency, b.task_id, foreign.task_id})

    assert {:error, "invalid task ID"} =
             Executor.run({:add_dependency, "nonsense", a.task_id})

    assert {:error, "not found"} =
             Executor.run({:add_dependency, "tsk-20260101T000000Z-deadbeef", a.task_id})
  end

  test "dependency edges gate task start and explain the block" do
    workflow = workflow("gate-deps")
    upstream = dependency_task(workflow, "gate-upstream")
    downstream = dependency_task(workflow, "gate-downstream")

    assert {:ok, _} = Executor.run({:add_dependency, downstream.task_id, upstream.task_id})

    for target <- [:proposed, :queued, :ready] do
      assert {:ok, _} = Executor.run({:transition_task, downstream.task_id, target, nil})
    end

    assert {:error, "task has incomplete predecessors"} =
             Executor.run({:transition_task, downstream.task_id, :in_progress, nil})

    assert {:ok, %{blocked: true}} = Executor.run({:list_dependencies, downstream.task_id})

    for target <- [:proposed, :queued, :ready, :in_progress, :completed] do
      assert {:ok, _} = Executor.run({:transition_task, upstream.task_id, target, nil})
    end

    assert {:ok, %{blocked: false}} = Executor.run({:list_dependencies, downstream.task_id})

    assert {:ok, %{state: :in_progress}} =
             Executor.run({:transition_task, downstream.task_id, :in_progress, nil})
  end

  defp dependency_task(workflow, suffix) do
    # Task.create sets the SOP acknowledgment itself via acknowledge_sop/1, so
    # the gate fields must not be passed as inputs here.
    {:ok, task} =
      Ash.create(Task, %{
        workflow_id: workflow.id,
        task_id: SpruceGoose.TaskId.generate(),
        title: "Dependency #{suffix}",
        definition_of_done: "Edge admission is governed",
        runner: :oban
      })

    task
  end

  test "CLI inbox captures are distinct per capture and remain non-executable" do
    assert {:ok, first} = Executor.run({:add_inbox, "Unclassified operator note"})
    assert {:ok, second} = Executor.run({:add_inbox, "Unclassified operator note"})

    # Capture identity is generated, so repeating the same note records a
    # genuinely separate capture rather than collapsing onto the first.
    assert first.id != second.id
    assert first.state == :pending
    assert second.state == :pending

    assert {:ok, %{items: items}} = Executor.run({:list_inbox, nil})
    assert Enum.sort(Enum.map(items, & &1.id)) == Enum.sort([first.id, second.id])
  end

  test "inbox triage resolves, drops, scopes listing, and fails closed on terminal captures" do
    {:ok, keep} = Executor.run({:add_inbox, "Capture to resolve"})
    {:ok, junk} = Executor.run({:add_inbox, "Capture to drop"})
    {:ok, open} = Executor.run({:add_inbox, "Capture left open"})

    assert {:ok, resolved} = Executor.run({:resolve_inbox, keep.id, nil})
    assert resolved.state == :resolved
    assert resolved.resolved_at

    assert {:ok, dropped} = Executor.run({:drop_inbox, junk.id, "not actionable"})
    assert dropped.state == :dropped
    assert dropped.resolution_reason == "not actionable"

    assert {:ok, %{items: pending}} = Executor.run({:list_inbox, nil})
    assert Enum.map(pending, & &1.id) == [open.id]

    assert {:ok, %{items: all}} = Executor.run({:list_inbox, "all"})
    assert length(all) == 3

    assert {:ok, %{items: [only_resolved]}} = Executor.run({:list_inbox, "resolved"})
    assert only_resolved.id == keep.id

    assert {:ok, %{items: [only_dropped]}} = Executor.run({:list_inbox, "dropped"})
    assert only_dropped.id == junk.id

    assert {:error, "state must be one of pending, resolved, dropped, all"} =
             Executor.run({:list_inbox, "bogus"})

    assert {:error, _} = Executor.run({:resolve_inbox, keep.id, nil})
    assert {:error, _} = Executor.run({:drop_inbox, keep.id, "already closed"})
    assert {:error, _} = Executor.run({:resolve_inbox, junk.id, nil})
    assert {:error, "not found"} = Executor.run({:resolve_inbox, "inbox-missing", nil})
  end

  test "inbox capture cannot bypass repository-bound task admission" do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "triage", kind: :oban}]})
    {:ok, project} = Ash.create(Project, %{key: "triage", name: "Triage"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{project_id: project.id, key: "intake", name: "Intake"})

    {:ok, _} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "promote",
        name: "Promote",
        definition: definition
      })

    membership = %{
      project: "triage",
      roadmap: "intake",
      workflow: "promote",
      priority: 2,
      task_type: :task,
      definition_of_done: "Capture is promoted",
      sop_path: SopGate.path()
    }

    {:ok, capture} = Executor.run({:add_inbox, "Promote this capture"})

    assert {:error, message} =
             Executor.run({:promote_inbox, capture.id, Map.put(membership, :title, nil)})

    assert message =~ "TaskDefinition"
    assert message =~ "task instantiate"

    assert {:ok, %{items: pending}} = Executor.run({:list_inbox, nil})
    assert capture.id in Enum.map(pending, & &1.id)
  end

  test "inbox promote leaves the capture open when task admission fails" do
    {:ok, capture} = Executor.run({:add_inbox, "Capture with bad membership"})

    assert {:error, _} =
             Executor.run(
               {:promote_inbox, capture.id,
                %{
                  project: "missing-project",
                  roadmap: "missing",
                  workflow: "missing",
                  priority: 3,
                  task_type: :task,
                  title: nil,
                  definition_of_done: "Should not be admitted",
                  sop_path: SopGate.path()
                }}
             )

    assert {:ok, %{items: pending}} = Executor.run({:list_inbox, nil})
    assert capture.id in Enum.map(pending, & &1.id)
  end

  defp list_fixture do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "admit", kind: :oban}]})
    {:ok, project} = Ash.create(Project, %{key: "listing", name: "Listing"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{project_id: project.id, key: "reads", name: "Reads"})

    {:ok, workflow} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "read-flow",
        name: "Read Flow",
        definition: definition
      })

    %{project: project, roadmap: roadmap, workflow: workflow}
  end

  defp admit(title, priority) do
    {:ok, task} =
      Executor.run({
        :add_task,
        %{
          project: "listing",
          roadmap: "reads",
          workflow: "read-flow",
          priority: priority,
          task_type: :task,
          title: title,
          definition_of_done: "Listed correctly",
          sop_path: SopGate.path()
        }
      })

    task
  end

  test "task list resolves human project roadmap and workflow membership" do
    list_fixture()
    task = admit("Membership is resolved", 1)

    assert {:ok, %{tasks: tasks}} = Executor.run({:list_tasks, %{workflow: "read-flow"}})
    row = Enum.find(tasks, &(&1.id == task.id))

    # The whole point: no UUID join required to learn where a task lives.
    assert row.project == "listing"
    assert row.roadmap == "reads"
    assert row.workflow == "read-flow"
    assert row.workflow_name == "Read Flow"
  end

  test "task list paginates with limit and offset while reporting the full total" do
    list_fixture()
    for n <- 1..5, do: admit("Paged #{n}", 2)

    assert {:ok, %{total: total, count: 2, offset: 0, limit: 2, tasks: page_one}} =
             Executor.run({:list_tasks, %{workflow: "read-flow", limit: 2}})

    assert total == 5
    assert length(page_one) == 2

    assert {:ok, %{total: 5, count: 2, offset: 2, tasks: page_two}} =
             Executor.run({:list_tasks, %{workflow: "read-flow", limit: 2, offset: 2}})

    # Pages must not overlap, or pagination is worse than useless.
    assert Enum.map(page_one, & &1.id) != Enum.map(page_two, & &1.id)
    assert MapSet.disjoint?(ids(page_one), ids(page_two))

    assert {:ok, %{total: 5, count: 1, tasks: tail}} =
             Executor.run({:list_tasks, %{workflow: "read-flow", limit: 2, offset: 4}})

    assert length(tail) == 1
  end

  defp ids(rows), do: rows |> Enum.map(& &1.id) |> MapSet.new()

  test "task list filters legacy null priority rows via none" do
    %{workflow: workflow} = list_fixture()
    prioritized = admit("Has priority", 3)

    # Simulate a pre-gate row admitted before priority was mandatory.
    {:ok, legacy} =
      Ash.create(Task, %{
        task_id: SpruceGoose.TaskId.generate(),
        title: "Legacy row",
        workflow_id: workflow.id,
        definition_of_done: "Grandfathered",
        runner: :oban,
        priority: nil
      })

    assert {:ok, %{tasks: none_rows}} =
             Executor.run({:list_tasks, %{workflow: "read-flow", priority: "none"}})

    none_ids = Enum.map(none_rows, & &1.id)
    assert legacy.task_id in none_ids
    refute prioritized.id in none_ids

    assert {:ok, %{tasks: three_rows}} =
             Executor.run({:list_tasks, %{workflow: "read-flow", priority: "3"}})

    assert Enum.map(three_rows, & &1.id) == [prioritized.id]

    assert {:error, "priority must be 0 through 5, or none"} =
             Executor.run({:list_tasks, %{priority: "abc"}})

    assert {:error, "priority must be 0 through 5, or none"} =
             Executor.run({:list_tasks, %{priority: "9"}})
  end

  test "task list accepts a comma separated state set" do
    list_fixture()
    waiting = admit("Will wait", 1)
    queued = admit("Will queue", 1)
    untouched = admit("Stays in inbox", 1)

    for target <- [:proposed, :queued] do
      {:ok, _} = Executor.run({:transition_task, queued.id, target, nil})
    end

    # waiting is only reachable from in_progress, which is SOP-gated.
    for target <- [:proposed, :queued, :ready, :in_progress] do
      {:ok, _} = Executor.run({:transition_task, waiting.id, target, nil})
    end

    {:ok, _} = Executor.run({:transition_task, waiting.id, :waiting, "holding"})

    assert {:ok, %{tasks: rows}} =
             Executor.run({:list_tasks, %{workflow: "read-flow", state: "waiting,queued"}})

    found = ids(rows)
    assert MapSet.member?(found, waiting.id)
    assert MapSet.member?(found, queued.id)
    refute MapSet.member?(found, untouched.id)

    assert {:error, "invalid task state"} =
             Executor.run({:list_tasks, %{state: "waiting,bogus"}})
  end

  test "leaving waiting clears its stale reason" do
    list_fixture()
    task = admit("Resume cleanly", 1)

    task =
      Enum.reduce([:proposed, :queued, :ready, :in_progress], task, fn target, current ->
        {:ok, transitioned} = Executor.run({:transition_task, current.id, target, nil})
        transitioned
      end)

    assert {:ok, waiting} = Executor.run({:transition_task, task.id, :waiting, "holding"})
    assert waiting.wait_reason == "holding"

    assert {:ok, resumed} = Executor.run({:transition_task, task.id, :ready, nil})
    assert resumed.wait_reason == nil
    assert resumed.cancel_reason == nil
  end

  test "task list sorts by priority and most recent" do
    list_fixture()
    low = admit("Low priority", 5)
    high = admit("High priority", 0)

    assert {:ok, %{tasks: by_priority}} =
             Executor.run({:list_tasks, %{workflow: "read-flow", sort: "priority"}})

    assert hd(by_priority).id == high.id
    assert List.last(by_priority).id == low.id

    assert {:ok, %{tasks: by_recent}} =
             Executor.run({:list_tasks, %{workflow: "read-flow", sort: "recent"}})

    # Task ids are lexically time-ordered, so "recent" is exactly descending id.
    # Task ids only carry second granularity and tiebreak on random hex, so two
    # rows admitted in the same second have no defined admission order. Assert
    # the ordering property rather than which specific row landed first.
    recent_ids = Enum.map(by_recent, & &1.id)
    assert recent_ids == Enum.sort(recent_ids, :desc)
    assert MapSet.new(recent_ids) == MapSet.new([high.id, low.id])

    assert {:error, "sort must be one of: created, id, priority, recent, state, title"} =
             Executor.run({:list_tasks, %{sort: "bogus"}})
  end

  test "workflow list reports task and open counts" do
    list_fixture()
    open = admit("Still open", 2)
    _second = admit("Also open", 2)

    for target <- [:proposed, :queued, :ready, :in_progress, :completed] do
      Executor.run({:transition_task, open.id, target, nil})
    end

    assert {:ok, %{workflows: workflows}} = Executor.run({:list_workflows, "listing", "reads"})
    row = Enum.find(workflows, &(&1.workflow_id == "read-flow"))

    assert row.task_count == 2
    assert row.open_count == 1
    assert row.state_counts["completed"] == 1
  end

  # A workflow_id is only unique within its roadmap. Two roadmaps under the
  # same project can both define "shared-flow", and matching on workflow_id
  # alone silently unions both -- a total the operator cannot account for.
  defp ambiguous_fixture do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "admit", kind: :oban}]})
    {:ok, project} = Ash.create(Project, %{key: "dual", name: "Dual"})

    for {roadmap_key, roadmap_name} <- [{"first", "First"}, {"second", "Second"}] do
      {:ok, roadmap} =
        Ash.create(Roadmap, %{project_id: project.id, key: roadmap_key, name: roadmap_name})

      {:ok, _workflow} =
        Ash.create(Workflow, %{
          roadmap_id: roadmap.id,
          workflow_id: "shared-flow",
          name: "Shared Flow",
          definition: definition
        })
    end

    for roadmap_key <- ["first", "second"] do
      {:ok, _task} =
        Executor.run({
          :add_task,
          %{
            project: "dual",
            roadmap: roadmap_key,
            workflow: "shared-flow",
            priority: 2,
            task_type: :task,
            title: "Lives in #{roadmap_key}",
            definition_of_done: "Scoped correctly",
            sop_path: SopGate.path()
          }
        })
    end

    :ok
  end

  test "task list rejects a workflow_id that is ambiguous across roadmaps" do
    ambiguous_fixture()

    assert {:error, message} = Executor.run({:list_tasks, %{workflow: "shared-flow"}})

    # Fail closed, and name both qualified paths so the caller can scope it.
    assert message =~ "ambiguous across 2 roadmaps"
    assert message =~ "dual/first/shared-flow"
    assert message =~ "dual/second/shared-flow"
    assert message =~ "--project"
  end

  test "scoping by roadmap disambiguates a shared workflow_id" do
    ambiguous_fixture()

    assert {:ok, %{tasks: [first]}} =
             Executor.run({:list_tasks, %{workflow: "shared-flow", roadmap: "first"}})

    assert first.title == "Lives in first"
    assert first.roadmap == "first"

    assert {:ok, %{tasks: [second]}} =
             Executor.run({:list_tasks, %{workflow: "shared-flow", roadmap: "second"}})

    assert second.title == "Lives in second"
    assert second.roadmap == "second"
  end

  test "an unambiguous workflow_id is unaffected by the ambiguity check" do
    list_fixture()
    task = admit("Still reachable unscoped", 2)

    # Only one roadmap defines read-flow, so no scoping should be required.
    assert {:ok, %{tasks: tasks}} = Executor.run({:list_tasks, %{workflow: "read-flow"}})
    assert Enum.any?(tasks, &(&1.id == task.id))
  end

  # Filtering, sorting, and pagination now run in Postgres rather than in
  # Elixir. Postgres does not sort the way Enum.sort_by/2 does, and with
  # --limit/--offset a different comparator returns *different rows* for the
  # same window, not merely the same rows reordered. These pin the comparator.
  test "title sort is case-insensitive, matching the previous in-memory order" do
    list_fixture()

    # Under the database's en_US.UTF-8 collation "apple" sorts before "Banana";
    # under a bare COLLATE "C" every capital sorts first, so "Banana" would
    # lead. Case-insensitive ordering is the behaviour being preserved.
    admit("banana lowercase", 2)
    admit("Apple capitalised", 2)
    admit("cherry lowercase", 2)

    assert {:ok, %{tasks: tasks}} =
             Executor.run({:list_tasks, %{workflow: "read-flow", sort: "title"}})

    assert Enum.map(tasks, & &1.title) == [
             "Apple capitalised",
             "banana lowercase",
             "cherry lowercase"
           ]
  end

  test "state sort keeps in_progress before inbox" do
    list_fixture()

    inbox_task = admit("Sits in inbox", 2)
    running = admit("Is running", 2)

    for target <- [:proposed, :queued, :ready, :in_progress] do
      Executor.run({:transition_task, running.id, target, nil})
    end

    assert {:ok, %{tasks: tasks}} =
             Executor.run({:list_tasks, %{workflow: "read-flow", sort: "state"}})

    ordered = Enum.map(tasks, & &1.id)

    # Byte order puts "in_progress" before "inbox"; the en_US collation ignores
    # the underscore and reverses them. Assert the byte-order result.
    assert Enum.find_index(ordered, &(&1 == running.id)) <
             Enum.find_index(ordered, &(&1 == inbox_task.id))
  end

  test "pagination windows the sorted set rather than an unsorted read" do
    list_fixture()

    for letter <- ["e", "d", "c", "b", "a"], do: admit("#{letter} title", 2)

    assert {:ok, %{tasks: page_one, total: total}} =
             Executor.run({:list_tasks, %{workflow: "read-flow", sort: "title", limit: 2}})

    assert {:ok, %{tasks: page_two}} =
             Executor.run({
               :list_tasks,
               %{workflow: "read-flow", sort: "title", limit: 2, offset: 2}
             })

    # total describes the whole match, not the window.
    assert total == 5
    assert Enum.map(page_one, & &1.title) == ["a title", "b title"]
    assert Enum.map(page_two, & &1.title) == ["c title", "d title"]
  end

  test "priority sort places null priority last" do
    %{workflow: workflow} = list_fixture()

    high = admit("High priority", 0)

    # Legacy rows predate the priority gate and are stored as NULL, so they
    # cannot be created through admission.
    {:ok, legacy} =
      Ash.create(SpruceGoose.Workflows.Task, %{
        workflow_id: workflow.id,
        task_id: "tsk-20260101T000000Z-0000dead",
        title: "Legacy null priority",
        definition_of_done: "Sorted last",
        runner: :oban,
        priority: nil
      })

    assert {:ok, %{tasks: tasks}} =
             Executor.run({:list_tasks, %{workflow: "read-flow", sort: "priority"}})

    ordered = Enum.map(tasks, & &1.id)
    assert List.last(ordered) == legacy.task_id
    assert Enum.find_index(ordered, &(&1 == high.id)) == 0
  end
end
