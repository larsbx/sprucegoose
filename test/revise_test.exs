defmodule SpruceGoose.ReviseTest do
  @moduledoc """
  The revise verb's contract. Most of these tests assert a *refusal*: the
  feature's whole point is that an unreviewed or stale change does not apply,
  so the gates are the thing worth pinning down.
  """

  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.{Command, Executor}
  alias SpruceGoose.Workflows.{Definition, Project, Roadmap, Task, Workflow}

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "sprucegoose-revise-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    # These tests are about the revise mechanics, so they run as one human who
    # holds every role and signs off on their own proposals with `--self`. The
    # proposer/approver split has its own coverage in `actors_test.exs`.
    actor("lars", :human)
    {:ok, tmp: tmp}
  end

  defp actor(name, kind, roles \\ [:reader, :operator, :proposer, :approver, :author]) do
    {:ok, actor} =
      Ash.create(
        SpruceGoose.Actors.Actor,
        %{name: name, kind: kind, created_by: "revise-test"},
        authorize?: false
      )

    for role <- roles do
      {:ok, _grant} =
        Ash.create(
          SpruceGoose.Actors.Grant,
          %{actor_id: actor.id, role: role, scope: "*", granted_by: "revise-test"},
          authorize?: false
        )
    end

    actor
  end

  describe "propose" do
    test "records the proposal, its digest, and the diff it would apply", %{tmp: tmp} do
      %{roadmap: roadmap} = fixtures("propose")
      path = toml(tmp, roadmap_document("propose", 1, ~s|name = "Renamed"|))

      assert {:ok, proposal} = Executor.run({:propose_revision, path}, "lars")

      assert proposal.state == :pending
      assert proposal.target_kind == :roadmap
      assert proposal.proposed_by == "lars"
      assert proposal.digest == sha256(File.read!(path))
      assert proposal.diff == %{"name" => %{before: roadmap.name, after: "Renamed"}}
      assert {:ok, _timestamp} = SpruceGoose.PrefixedId.parse("rev", proposal.revision)
    end

    test "refuses a relative --file, because the service reads it and not the caller's shell" do
      assert {:error, message} = Executor.run({:propose_revision, "revision.toml"}, "lars")
      assert message =~ "absolute path"
    end

    test "refuses a [change] key the entity does not expose", %{tmp: tmp} do
      fixtures("unknown-key")
      path = toml(tmp, roadmap_document("unknown-key", 1, ~s|colour = "blue"|))

      assert {:error, message} = Executor.run({:propose_revision, path}, "lars")
      assert message =~ "unsupported keys: colour"
    end

    test "refuses an identity key by name, since the vault references entities by it", %{tmp: tmp} do
      fixtures("identity-key")
      path = toml(tmp, roadmap_document("identity-key", 1, ~s|key = "renamed"|))

      assert {:error, message} = Executor.run({:propose_revision, path}, "lars")
      assert message =~ "identifies the roadmap and cannot be revised"
    end

    test "refuses a lock_version that does not match the target", %{tmp: tmp} do
      fixtures("stale-propose")
      path = toml(tmp, roadmap_document("stale-propose", 7, ~s|name = "Renamed"|))

      assert {:error, message} = Executor.run({:propose_revision, path}, "lars")
      assert message =~ "lock_version 1, not the 7"
    end

    test "refuses a workflow DAG with a cycle, before it can reach sign-off", %{tmp: tmp} do
      fixtures("cyclic")

      path =
        toml(tmp, """
        target = "workflow:project-cyclic/roadmap-cyclic/workflow-cyclic"
        expect_lock_version = 1
        reason = "introduce a cycle"

        [change.definition]
        schema_version = 1

        [[change.definition.tasks]]
        id = "a"
        kind = "oban"
        depends_on = ["b"]

        [[change.definition.tasks]]
        id = "b"
        kind = "oban"
        depends_on = ["a"]
        """)

      assert {:error, _error} = Executor.run({:propose_revision, path}, "lars")
      assert {:ok, %{revisions: []}} = Executor.run({:list_revisions, "all", nil}, "lars")
    end

    test "refuses malformed TOML and a missing reason", %{tmp: tmp} do
      fixtures("malformed")

      assert {:error, invalid} =
               Executor.run({:propose_revision, toml(tmp, "target = [")}, "lars")

      assert invalid =~ "invalid TOML"

      no_reason =
        toml(tmp, """
        target = "roadmap:project-malformed/roadmap-malformed"
        expect_lock_version = 1

        [change]
        name = "Renamed"
        """)

      assert {:error, message} = Executor.run({:propose_revision, no_reason}, "lars")
      assert message =~ "reason is required"
    end
  end

  describe "approve" do
    test "applies the change and records who signed it off against which bytes", %{tmp: tmp} do
      %{roadmap: roadmap} = fixtures("approve")
      path = toml(tmp, roadmap_document("approve", 1, ~s|name = "Driftless Ops (2026-H2)"|))

      {:ok, proposal} = Executor.run({:propose_revision, path}, "lars")
      task = in_progress_task("approve")

      assert {:ok, applied} =
               Executor.run(
                 {:approve_revision, proposal.revision, task.task_id, proposal.digest, true},
                 "lars"
               )

      assert applied.state == :applied
      assert applied.approved_by == "lars"
      assert applied.authorizing_task == task.task_id
      assert applied.applied_lock_version == 2

      assert {:ok, reloaded} = Ash.get(Roadmap, roadmap.id)
      assert reloaded.name == "Driftless Ops (2026-H2)"
      assert reloaded.lock_version == 2
    end

    test "refuses a digest that was not quoted back from show", %{tmp: tmp} do
      %{roadmap: roadmap} = fixtures("wrong-digest")
      path = toml(tmp, roadmap_document("wrong-digest", 1, ~s|name = "Renamed"|))

      {:ok, proposal} = Executor.run({:propose_revision, path}, "lars")
      task = in_progress_task("wrong-digest")

      assert {:error, message} =
               Executor.run(
                 {:approve_revision, proposal.revision, task.task_id, String.duplicate("a", 64),
                  true},
                 "lars"
               )

      assert message =~ "--digest does not match"
      assert pending?(proposal.revision)
      assert {:ok, %{name: unchanged}} = Ash.get(Roadmap, roadmap.id)
      assert unchanged == roadmap.name
    end

    test "refuses without an authorizing task, and with one that is not in progress", %{tmp: tmp} do
      fixtures("authority")
      path = toml(tmp, roadmap_document("authority", 1, ~s|name = "Renamed"|))
      {:ok, proposal} = Executor.run({:propose_revision, path}, "lars")

      assert {:error, missing} =
               Executor.run(
                 {:approve_revision, proposal.revision, "", proposal.digest, true},
                 "lars"
               )

      assert missing =~ "--task"

      idle = gated_task("authority-idle")

      assert {:error, state} =
               Executor.run(
                 {:approve_revision, proposal.revision, idle.task_id, proposal.digest, true},
                 "lars"
               )

      assert state =~ "is inbox; approval requires an in_progress task"
      assert pending?(proposal.revision)
    end

    test "refuses when the authorizing task's SOP acknowledgment has gone stale", %{tmp: tmp} do
      fixtures("stale-sop")
      path = toml(tmp, roadmap_document("stale-sop", 1, ~s|name = "Renamed"|))
      {:ok, proposal} = Executor.run({:propose_revision, path}, "lars")
      task = in_progress_task("stale-sop")

      # Reconfigure the SOP after the task acknowledged it: exactly what a real
      # SOP edit does to every task holding an acknowledgment of the old bytes.
      original = Application.fetch_env!(:spruce_goose, :systemwide_sop_path)
      alternate = Path.join(System.tmp_dir!(), "sprucegoose-revise-sop.md")
      File.write!(alternate, "# Alternate Systemwide SOP\n")
      Application.put_env(:spruce_goose, :systemwide_sop_path, alternate)

      on_exit(fn ->
        Application.put_env(:spruce_goose, :systemwide_sop_path, original)
        File.rm(alternate)
      end)

      assert {:error, message} =
               Executor.run(
                 {:approve_revision, proposal.revision, task.task_id, proposal.digest, true},
                 "lars"
               )

      assert message =~ "Systemwide SOP"
      assert pending?(proposal.revision)
    end

    test "refuses once the target has moved since the proposal", %{tmp: tmp} do
      %{roadmap: roadmap} = fixtures("stale-target")
      path = toml(tmp, roadmap_document("stale-target", 1, ~s|name = "Renamed"|))
      {:ok, proposal} = Executor.run({:propose_revision, path}, "lars")
      task = in_progress_task("stale-target")

      {:ok, _renamed} = Ash.update(roadmap, %{name: "Renamed Elsewhere"}, action: :rename)

      assert {:error, message} =
               Executor.run(
                 {:approve_revision, proposal.revision, task.task_id, proposal.digest, true},
                 "lars"
               )

      assert message =~ "changed since the proposal"
      assert pending?(proposal.revision)
    end

    test "editing the source file after proposing changes nothing", %{tmp: tmp} do
      %{roadmap: roadmap} = fixtures("immutable")
      path = toml(tmp, roadmap_document("immutable", 1, ~s|name = "Reviewed"|))
      {:ok, proposal} = Executor.run({:propose_revision, path}, "lars")

      File.write!(path, roadmap_document("immutable", 1, ~s|name = "Substituted"|))
      task = in_progress_task("immutable")

      assert {:ok, _applied} =
               Executor.run(
                 {:approve_revision, proposal.revision, task.task_id, proposal.digest, true},
                 "lars"
               )

      assert {:ok, %{name: "Reviewed"}} = Ash.get(Roadmap, roadmap.id)
    end

    test "applies a revised workflow DAG", %{tmp: tmp} do
      %{workflow: workflow} = fixtures("dag")

      path =
        toml(tmp, """
        target = "workflow:project-dag/roadmap-dag/workflow-dag"
        expect_lock_version = 1
        reason = "add the rehearsal phase"

        [change]
        name = "Rehearsed workflow"

        [change.definition]
        schema_version = 1

        [[change.definition.tasks]]
        id = "task-dag"
        kind = "oban"

        [[change.definition.tasks]]
        id = "rehearsal"
        kind = "oban"
        depends_on = ["task-dag"]
        """)

      {:ok, proposal} = Executor.run({:propose_revision, path}, "lars")
      task = in_progress_task("dag")

      assert {:ok, _applied} =
               Executor.run(
                 {:approve_revision, proposal.revision, task.task_id, proposal.digest, true},
                 "lars"
               )

      assert {:ok, reloaded} = Ash.get(Workflow, workflow.id)
      assert reloaded.name == "Rehearsed workflow"
      assert Enum.map(reloaded.definition.tasks, & &1.id) == ["task-dag", "rehearsal"]
    end
  end

  describe "show, list and withdraw" do
    test "show reproduces the reviewed bytes and the diff", %{tmp: tmp} do
      fixtures("show")
      body = roadmap_document("show", 1, ~s|name = "Renamed"|)
      path = toml(tmp, body)
      {:ok, proposal} = Executor.run({:propose_revision, path}, "lars")

      assert {:ok, shown} = Executor.run({:show_revision, proposal.revision}, "lars")
      assert shown.source_body == body
      assert shown.digest == sha256(body)
      # The invariant that makes --digest mean anything: the stored body is
      # byte-exact, so what was signed off can always be re-derived from it.
      assert sha256(shown.source_body) == shown.digest
      assert shown.diff == %{"name" => %{before: "Roadmap show", after: "Renamed"}}
    end

    test "list defaults to pending and can be scoped by state", %{tmp: tmp} do
      fixtures("list")
      path = toml(tmp, roadmap_document("list", 1, ~s|name = "Renamed"|))
      {:ok, proposal} = Executor.run({:propose_revision, path}, "lars")

      assert {:ok, %{revisions: [pending]}} = Executor.run({:list_revisions, nil, nil}, "lars")
      assert pending.revision == proposal.revision

      assert {:ok, %{revisions: []}} = Executor.run({:list_revisions, "applied", nil}, "lars")
      assert {:error, message} = Executor.run({:list_revisions, "bogus", nil}, "lars")
      assert message =~ "state must be one of"
    end

    test "a withdrawn revision cannot be approved", %{tmp: tmp} do
      fixtures("withdraw")
      path = toml(tmp, roadmap_document("withdraw", 1, ~s|name = "Renamed"|))
      {:ok, proposal} = Executor.run({:propose_revision, path}, "lars")

      assert {:ok, withdrawn} =
               Executor.run(
                 {:withdraw_revision, proposal.revision, "superseded by the H2 rescope"},
                 "lars"
               )

      assert withdrawn.state == :withdrawn
      task = in_progress_task("withdraw")

      assert {:error, message} =
               Executor.run(
                 {:approve_revision, proposal.revision, task.task_id, proposal.digest, true},
                 "lars"
               )

      assert message =~ "already withdrawn"
    end
  end

  describe "command parsing" do
    test "approve requires every sign-off flag" do
      assert {:error, "--digest is required"} =
               Command.parse(["revise", "approve", "rev-1", "--task", "tsk-1"])

      assert {:error, "--task is required"} =
               Command.parse(["revise", "approve", "rev-1", "--digest", "abc"])

      assert {:error, "--task is required"} = Command.parse(["revise", "approve", "rev-1"])

      assert {:ok, {:approve_revision, "rev-1", "tsk-1", "abc", true}} =
               Command.parse([
                 "revise",
                 "approve",
                 "rev-1",
                 "--task",
                 "tsk-1",
                 "--digest",
                 "abc",
                 "--self"
               ])
    end

    test "propose requires --file, and the actor comes from the global --as" do
      assert {:error, "--file is required"} = Command.parse(["revise", "propose"])

      assert {:ok, {:propose_revision, "/tmp/rev.toml"}} =
               Command.parse(["revise", "propose", "--file", "/tmp/rev.toml"])

      # --as is stripped before parse/1 ever sees it, on every verb.
      assert {"openclaw", ["revise", "propose", "--file", "/tmp/rev.toml"]} =
               Command.extract_actor([
                 "revise",
                 "propose",
                 "--as",
                 "openclaw",
                 "--file",
                 "/tmp/rev.toml"
               ])
    end

    test "the revise verb appears in help" do
      assert %{commands: %{"revise" => forms}} = Command.help()
      assert Enum.any?(forms, &String.starts_with?(&1, "approve"))
    end
  end

  # -- fixtures ---------------------------------------------------------------

  defp fixtures(suffix) do
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

    %{project: project, roadmap: roadmap, workflow: workflow}
  end

  defp gated_task(suffix) do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "gate-#{suffix}", kind: :oban}]})
    {:ok, project} = Ash.create(Project, %{key: "gate-#{suffix}", name: "Gate #{suffix}"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{project_id: project.id, key: "gate-#{suffix}", name: "Gate #{suffix}"})

    {:ok, workflow} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "gate-#{suffix}",
        name: "Gate #{suffix}",
        definition: definition
      })

    {:ok, task} =
      Ash.create(Task, %{
        workflow_id: workflow.id,
        task_id: SpruceGoose.TaskId.generate(),
        title: "Authorize #{suffix}",
        definition_of_done: "the revision is signed off",
        runner: :oban
      })

    task
  end

  defp in_progress_task(suffix) do
    suffix
    |> gated_task()
    |> advance([:proposed, :queued, :ready, :in_progress])
  end

  defp advance(task, states) do
    Enum.reduce(states, task, fn state, current ->
      {:ok, moved} =
        current
        |> Ash.Changeset.for_update(:transition, %{to_state: state})
        |> Ash.update()

      moved
    end)
  end

  defp roadmap_document(suffix, lock_version, change) do
    """
    target = "roadmap:project-#{suffix}/roadmap-#{suffix}"
    expect_lock_version = #{lock_version}
    reason = "test fixture for #{suffix}"

    [change]
    #{change}
    """
  end

  defp toml(tmp, body) do
    path = Path.join(tmp, "revision-#{System.unique_integer([:positive])}.toml")
    File.write!(path, body)
    path
  end

  defp pending?(revision_id) do
    {:ok, shown} = Executor.run({:show_revision, revision_id}, "lars")
    shown.state == :pending
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
