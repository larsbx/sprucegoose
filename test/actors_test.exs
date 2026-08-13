defmodule SpruceGoose.ActorsTest do
  @moduledoc """
  Scoped roles, and what they refuse.

  Almost every assertion here is a refusal with a *specific* message. A
  permission system that refuses with "unauthorized" teaches nobody what grant
  they are missing, and on a fleet where agents read their own error output that
  matters more than usual.
  """

  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Actors.{Actor, Grant, Registry, Resolver, Scope}
  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Workflows.{Definition, Dependency, Project, Roadmap, Task, Workflow}

  @genesis_roles ~w(admin approver artifact_verifier author operator proposer reader)a

  describe "genesis" do
    test "an empty registry creates its first actor as a global admin" do
      empty_registry()

      assert {:ok, genesis} =
               Executor.run({:add_actor, %{name: "lars", kind: :human, description: nil}})

      assert genesis.genesis == true
      assert genesis.actor == "lars"
      assert genesis.created_by == "genesis"
      assert %{role: :admin, scope: "*"} = hd(genesis.grants)
      assert genesis.note =~ "registry was empty"
    end

    test "concurrent first-actor requests admit exactly one complete genesis actor" do
      empty_registry()
      parent = self()

      contenders =
        for index <- 1..64 do
          Elixir.Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :go ->
                Executor.run(
                  {:add_actor,
                   %{name: "genesis-#{index}", kind: :human, description: "concurrent genesis"}}
                )
            end
          end)
        end

      pids =
        for _ <- contenders do
          assert_receive {:ready, pid}, 5_000
          pid
        end

      Enum.each(pids, &send(&1, :go))
      results = Enum.map(contenders, &Elixir.Task.await(&1, 15_000))
      actors = Ash.read!(Actor, authorize?: false)
      grants = Ash.read!(Grant, authorize?: false)

      assert Enum.count(results, &match?({:ok, %{genesis: true}}, &1)) == 1
      assert length(actors) == 1

      assert grants
             |> Enum.map(&{&1.role, &1.scope, &1.actor_id, &1.granted_by})
             |> Enum.sort() ==
               Enum.map(
                 @genesis_roles,
                 &{&1, "*", hd(actors).id, "genesis"}
               )
               |> Enum.sort()
    end

    test "a Genesis grant failure rolls back the actor and every grant" do
      empty_registry()

      Repo.query!("""
      CREATE FUNCTION corr7_reject_approver_grant() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.role = 'approver' THEN
          RAISE EXCEPTION 'injected Genesis grant failure';
        END IF;
        RETURN NEW;
      END
      $$
      """)

      Repo.query!("""
      CREATE TRIGGER corr7_reject_approver_grant
      BEFORE INSERT ON actor_grants
      FOR EACH ROW EXECUTE FUNCTION corr7_reject_approver_grant()
      """)

      assert {:error, _error} =
               Executor.run(
                 {:add_actor,
                  %{name: "rollback-genesis", kind: :human, description: "must not persist"}}
               )

      assert Ash.read!(Actor, authorize?: false) == []
      assert Ash.read!(Grant, authorize?: false) == []
    end

    test "a configured Genesis identity rejects every other first actor" do
      empty_registry()
      previous = Application.get_env(:spruce_goose, :expected_genesis_actor)
      Application.put_env(:spruce_goose, :expected_genesis_actor, "expected-genesis")

      on_exit(fn ->
        if previous do
          Application.put_env(:spruce_goose, :expected_genesis_actor, previous)
        else
          Application.delete_env(:spruce_goose, :expected_genesis_actor)
        end
      end)

      assert {:error, message} =
               Executor.run(
                 {:add_actor,
                  %{name: "wrong-genesis", kind: :human, description: "must be refused"}}
               )

      assert message =~ "expected Genesis actor expected-genesis"
      assert Ash.read!(Actor, authorize?: false) == []
      assert Ash.read!(Grant, authorize?: false) == []

      assert {:ok, %{actor: "expected-genesis", genesis: true}} =
               Executor.run(
                 {:add_actor,
                  %{name: "expected-genesis", kind: :human, description: "configured authority"}}
               )
    end

    test "the first actor must be human, because an empty registry holds nobody accountable" do
      empty_registry()

      assert {:error, message} =
               Executor.run({:add_actor, %{name: "openclaw", kind: :agent, description: nil}})

      assert message =~ "must be --kind human"
    end

    test "genesis closes once an actor exists, and an unnamed caller is refused" do
      Application.put_env(:spruce_goose, :default_actor, nil)
      on_exit(fn -> Application.put_env(:spruce_goose, :default_actor, "test-system") end)

      assert {:error, message} =
               Executor.run({:add_actor, %{name: "openclaw", kind: :agent, description: nil}})

      assert message =~ "require an actor"
    end

    test "an admin can register further actors" do
      assert {:ok, added} =
               Executor.run(
                 {:add_actor, %{name: "openclaw", kind: :agent, description: "gateway agent"}},
                 system()
               )

      assert added.actor == "openclaw"
      assert added.kind == :agent
      assert added.created_by == system()
      refute Map.has_key?(added, :genesis)
    end

    test "a stale resolved admin cannot register an actor after being disabled" do
      actor("backup-admin", :human, admin: "*")
      assert {:ok, stale_admin} = Resolver.resolve(system())

      assert {:ok, _disabled} =
               Executor.run(
                 {:disable_actor, system(), "authorization revoked during request"},
                 "backup-admin"
               )

      assert {:error, message} =
               Registry.add(
                 %{name: "late-actor", kind: :agent, description: nil},
                 stale_admin
               )

      assert message =~ "is disabled"
      refute Enum.any?(Ash.read!(Actor, authorize?: false), &(&1.name == "late-actor"))
    end

    test "a stale resolved admin cannot register an actor after admin is revoked" do
      actor("backup-admin", :human, admin: "*")
      assert {:ok, stale_admin} = Resolver.resolve(system())

      assert {:ok, _revoked} =
               Executor.run({:revoke_role, system(), "admin", "*"}, "backup-admin")

      assert {:error, message} =
               Registry.add(
                 %{name: "late-actor", kind: :agent, description: nil},
                 stale_admin
               )

      assert message =~ "does not hold admin"
      refute Enum.any?(Ash.read!(Actor, authorize?: false), &(&1.name == "late-actor"))
    end
  end

  describe "the registry gate" do
    test "a non-admin cannot register actors or grant roles" do
      actor("openclaw", :agent, proposer: "*")

      assert {:error, message} =
               Executor.run(
                 {:add_actor, %{name: "pi", kind: :agent, description: nil}},
                 "openclaw"
               )

      assert message =~ "does not hold admin"

      assert {:error, grant_message} =
               Executor.run({:grant_role, "openclaw", "approver", "*"}, "openclaw")

      assert grant_message =~ "does not hold admin"
    end

    test "a grant naming a project that does not exist is refused" do
      assert {:error, message} =
               Executor.run({:grant_role, system(), "proposer", "project:nope"}, system())

      assert message =~ ~s(no project "nope")
    end

    test "a disabled backup admin does not permit revoking the last active global admin" do
      actor("disabled-backup-admin", :human, admin: "*")

      assert {:ok, _disabled} =
               Executor.run(
                 {:disable_actor, "disabled-backup-admin", "not available for recovery"},
                 system()
               )

      assert {:error, message} =
               Executor.run({:revoke_role, system(), "admin", "*"}, system())

      assert message =~ "last active global admin"
      assert {:ok, current_admin} = Resolver.resolve(system())
      assert Scope.holds?(current_admin, :admin, "*")
    end

    test "the last global admin grant cannot be revoked" do
      assert {:error, message} =
               Executor.run({:revoke_role, system(), "admin", "*"}, system())

      assert message =~ "last global admin"
    end

    test "whoami reports the caller's own grants without needing admin" do
      actor("openclaw", :agent, proposer: "project:alpha")

      assert {:ok, me} = Executor.run(:whoami, "openclaw")
      assert me.actor == "openclaw"
      assert me.kind == :agent
      assert [%{role: :proposer, scope: "project:alpha"}] = me.grants
    end
  end

  describe "resolution" do
    test "an unknown or absent actor is refused with a way forward" do
      assert {:error, unknown} = Resolver.resolve("nobody")
      assert unknown =~ "unknown actor"
      assert unknown =~ "actor add"

      Application.put_env(:spruce_goose, :default_actor, nil)
      on_exit(fn -> Application.put_env(:spruce_goose, :default_actor, "test-system") end)

      assert {:error, absent} = Resolver.resolve(nil)
      assert absent =~ "--as"
    end

    test "a disabled actor is refused everything, including reads" do
      openclaw = actor("openclaw", :agent, reader: "*")
      {:ok, _} = Ash.update(openclaw, %{disabled_reason: "rotated out"}, action: :disable)

      assert {:error, message} = Executor.run(:list_projects, "openclaw")
      assert message =~ "is disabled"
      assert message =~ "rotated out"
    end

    test "resolution works for an actor holding no reader grant at all" do
      # The registry is what every policy check reads. If resolving an actor
      # were itself subject to those policies, authorization would depend on
      # being authorized and a fresh actor could never be used.
      ungranted = actor("ungranted", :agent, [])

      assert {:ok, resolved} = Resolver.resolve("ungranted")
      assert resolved.id == ungranted.id
      assert Scope.summary(resolved) == []
    end
  end

  describe "scoped reads" do
    test "a project-scoped reader sees its slice, filtered rather than refused" do
      %{task: alpha_task} = fixtures("alpha")
      fixtures("beta")
      actor("openclaw", :agent, reader: "project:alpha")

      assert {:ok, %{tasks: tasks}} = Executor.run({:list_tasks, %{}}, "openclaw")
      assert Enum.map(tasks, & &1.id) == [alpha_task.task_id]

      assert {:ok, %{projects: projects}} = Executor.run(:list_projects, "openclaw")
      assert Enum.map(projects, & &1.key) == ["alpha"]
    end

    test "an actor with no grants is refused, rather than shown an empty world" do
      fixtures("alpha")
      actor("blind", :agent, [])

      # A scoped reader filters; a grantless one is refused. "You hold no
      # grants" is actionable where an empty list reads as "no data exists" —
      # and the refusal names the command that fixes it.
      assert {:error, message} = Executor.run(:list_projects, "blind")
      assert message =~ "actor blind is not authorized to Project.read"
      assert message =~ "holds no grants at all"
      assert message =~ "sprucegoose grant add blind --role ROLE --scope SCOPE"
    end

    test "dependency graph queries stay inside the actor's readable project and workflow" do
      alpha = fixtures("alpha")
      beta = fixtures("beta")
      alpha_successor = successor(alpha, "Alpha successor")
      beta_successor = successor(beta, "Beta successor")
      actor("graph-reader", :agent, reader: "project:alpha")

      assert {:ok, %{impacted: [%{id: alpha_id}]}} =
               Executor.run({:task_impact, alpha.task.task_id}, "graph-reader")

      assert alpha_id == alpha_successor.task_id
      refute alpha_id == beta_successor.task_id

      assert {:ok, %{path: alpha_path}} =
               Executor.run(
                 {:workflow_critical_path, "alpha", "r-alpha", "w-alpha"},
                 "graph-reader"
               )

      assert Enum.map(alpha_path, & &1.id) == [alpha.task.task_id, alpha_successor.task_id]

      assert {:error, _refused} =
               Executor.run({:task_blockers, beta_successor.task_id}, "graph-reader")

      assert {:error, _refused} =
               Executor.run({:task_impact, beta.task.task_id}, "graph-reader")

      assert {:error, _refused} =
               Executor.run(
                 {:workflow_critical_path, "beta", "r-beta", "w-beta"},
                 "graph-reader"
               )
    end
  end

  describe "scoped writes" do
    test "an operator may drive tasks in its project and not in another" do
      %{task: alpha_task} = fixtures("alpha")
      %{task: beta_task} = fixtures("beta")
      actor("openclaw", :agent, operator: "project:alpha")

      assert {:ok, _} =
               Executor.run({:transition_task, alpha_task.task_id, :proposed, nil}, "openclaw")

      assert {:error, _refused} =
               Executor.run({:transition_task, beta_task.task_id, :proposed, nil}, "openclaw")
    end

    test "an operator cannot create structural entities" do
      actor("openclaw", :agent, operator: "*")

      assert {:error, _message} = Executor.run({:add_project, "new", "New"}, "openclaw")
    end
  end

  describe "the proposer/approver split" do
    setup do
      fixtures("alpha")
      fixtures("beta")
      :ok
    end

    test "a proposer may propose in its project and not in another", %{} do
      actor("openclaw", :agent, proposer: "project:alpha", reader: "*")

      assert {:ok, proposal} =
               Executor.run({:propose_revision, revision_toml("alpha")}, "openclaw")

      assert proposal.proposed_by == "openclaw"
      assert proposal.project_key == "alpha"

      assert {:error, _refused} =
               Executor.run({:propose_revision, revision_toml("beta")}, "openclaw")
    end

    test "a proposer is refused approval" do
      actor("openclaw", :agent, proposer: "*", reader: "*")
      actor("lars", :human, approver: "*", reader: "*", operator: "*")

      {:ok, proposal} = Executor.run({:propose_revision, revision_toml("alpha")}, "openclaw")
      task = in_progress_task("alpha-approve")

      assert {:error, _refused} =
               Executor.run(
                 {:approve_revision, proposal.revision, task.task_id, proposal.digest, false},
                 "openclaw"
               )

      assert {:ok, applied} =
               Executor.run(
                 {:approve_revision, proposal.revision, task.task_id, proposal.digest, false},
                 "lars"
               )

      assert applied.approved_by == "lars"
      assert applied.self_approved == false
    end

    test "an agent cannot approve its own proposal even holding both roles" do
      actor("openclaw", :agent, proposer: "*", approver: "*", reader: "*", operator: "*")

      {:ok, proposal} = Executor.run({:propose_revision, revision_toml("alpha")}, "openclaw")
      task = in_progress_task("agent-self")

      for self? <- [false, true] do
        assert {:error, message} =
                 Executor.run(
                   {:approve_revision, proposal.revision, task.task_id, proposal.digest, self?},
                   "openclaw"
                 )

        assert message =~ "is an agent; only a human may approve"
      end
    end

    test "a human must ask for self-approval, and it is recorded when they do" do
      actor("lars", :human, proposer: "*", approver: "*", reader: "*", operator: "*")

      {:ok, proposal} = Executor.run({:propose_revision, revision_toml("alpha")}, "lars")
      task = in_progress_task("human-self")

      assert {:error, message} =
               Executor.run(
                 {:approve_revision, proposal.revision, task.task_id, proposal.digest, false},
                 "lars"
               )

      assert message =~ "pass --self"

      assert {:ok, applied} =
               Executor.run(
                 {:approve_revision, proposal.revision, task.task_id, proposal.digest, true},
                 "lars"
               )

      assert applied.self_approved == true
    end
  end

  # -- fixtures ---------------------------------------------------------------

  defp system, do: Application.fetch_env!(:spruce_goose, :default_actor)

  defp empty_registry do
    for grant <- Ash.read!(Grant, authorize?: false), do: Ash.destroy!(grant, authorize?: false)
    for actor <- Ash.read!(Actor, authorize?: false), do: Ash.destroy!(actor, authorize?: false)
    :ok
  end

  defp actor(name, kind, grants) do
    {:ok, actor} =
      Ash.create(Actor, %{name: name, kind: kind, created_by: "actors-test"}, authorize?: false)

    for {role, scope} <- grants do
      {:ok, _grant} =
        Ash.create(
          Grant,
          %{actor_id: actor.id, role: role, scope: scope, granted_by: "actors-test"},
          authorize?: false
        )
    end

    actor
  end

  defp fixtures(key) do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "t-#{key}", kind: :oban}]})
    {:ok, project} = Ash.create(Project, %{key: key, name: "Project #{key}"}, authorize?: false)

    {:ok, roadmap} =
      Ash.create(
        Roadmap,
        %{project_id: project.id, key: "r-#{key}", name: "Roadmap #{key}"},
        authorize?: false
      )

    {:ok, workflow} =
      Ash.create(
        Workflow,
        %{
          roadmap_id: roadmap.id,
          workflow_id: "w-#{key}",
          name: "Workflow #{key}",
          definition: definition
        },
        authorize?: false
      )

    {:ok, task} =
      Ash.create(
        Task,
        %{
          workflow_id: workflow.id,
          task_id: SpruceGoose.TaskId.generate(),
          title: "Task #{key}",
          definition_of_done: "scoped roles hold",
          runner: :oban
        },
        authorize?: false
      )

    %{project: project, roadmap: roadmap, workflow: workflow, task: task}
  end

  defp successor(fixture, title) do
    {:ok, task} =
      Ash.create(
        Task,
        %{
          workflow_id: fixture.workflow.id,
          task_id: SpruceGoose.TaskId.generate(),
          title: title,
          definition_of_done: "graph scope holds",
          runner: :oban
        },
        authorize?: false
      )

    {:ok, _edge} =
      Ash.create(
        Dependency,
        %{predecessor_id: fixture.task.id, successor_id: task.id, source: "native"},
        authorize?: false
      )

    task
  end

  defp in_progress_task(suffix) do
    %{task: task} = fixtures("gate-#{suffix}")

    Enum.reduce([:proposed, :queued, :ready, :in_progress], task, fn state, current ->
      {:ok, moved} =
        current
        |> Ash.Changeset.for_update(:transition, %{to_state: state})
        |> Ash.update(authorize?: false)

      moved
    end)
  end

  defp revision_toml(key) do
    path =
      Path.join(
        System.tmp_dir!(),
        "sprucegoose-actors-#{key}-#{System.unique_integer([:positive])}.toml"
      )

    File.write!(path, """
    target = "roadmap:#{key}/r-#{key}"
    expect_lock_version = 1
    reason = "scoped role fixture for #{key}"

    [change]
    name = "Roadmap #{key} revised"
    """)

    on_exit(fn -> File.rm(path) end)
    path
  end
end
