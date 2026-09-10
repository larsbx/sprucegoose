defmodule SpruceGoose.DeploymentTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Actors.{Actor, Grant}
  alias SpruceGoose.{Authz, Deployment}
  alias SpruceGoose.Deployment.{Authorization, Executor, Ledger, Operation, Record, Release}
  alias SpruceGoose.Derivations.{OutcomeReceipt, Permit}
  alias SpruceGoose.Workflows.{Definition, Project, Roadmap, Task, Workflow}

  @commit String.duplicate("a", 40)
  @archive String.duplicate("1", 64)
  @other_archive String.duplicate("2", 64)
  @roots Map.new(
           ~w(ontology schema norm policy grant_epoch agent_charter interpreter evidence_policy),
           &{&1, "sha256:" <> String.duplicate("e", 64)}
         )

  defmodule SucceedingAdapter do
    def execute(%{operation_id: id}),
      do: {:ok, %{evidence_digest: String.duplicate("f", 64), detail: "applied " <> id}}

    def observe(_request), do: {:ok, %{status: :succeeded, detail: "running"}}
  end

  defmodule FailingAdapter do
    def execute(_request), do: {:error, "systemctl restart failed"}
    def observe(_request), do: {:ok, %{status: :failed, detail: "service inactive"}}
  end

  # Never returns within the executor timeout; the host answers inspection
  # with whatever the test configured, so the reconcile path is exercised.
  defmodule HangingAdapter do
    def execute(_request), do: Process.sleep(:infinity)
    def observe(_request), do: {:ok, Application.get_env(:spruce_goose, :test_host_observation)}
  end

  setup do
    previous =
      Enum.map(
        ~w(deployment_executor_actor deployment_host_adapter deployment_operation_timeout_ms test_host_observation)a,
        &{&1, Application.get_env(:spruce_goose, &1)}
      )

    on_exit(fn ->
      Enum.each(previous, fn {k, v} ->
        if is_nil(v),
          do: Application.delete_env(:spruce_goose, k),
          else: Application.put_env(:spruce_goose, k, v)
      end)
    end)

    system = Ash.read_one!(Ash.Query.filter_input(Actor, name: "test-system"), authorize?: false)
    {:ok, system: system}
  end

  # --- release acceptance (Woodpecker evidence binding) ---------------------------------

  test "a release is accepted only against verified archive custody in its own project", %{
    system: system
  } do
    project = project_with_custody("accept", @archive)
    other = project_with_custody("accept-other", @other_archive)

    assert {:ok, release} =
             as(system, fn -> Deployment.accept_release(project.key, release_attrs(@archive)) end)

    assert "rel-" <> _ = release.release_id
    assert release.accepted_by == system.name
    assert release.artifacts == %{"archive" => "sha256:" <> @archive}

    # Same identity, same ID: acceptance is deterministic, and a repeat is refused as a duplicate.
    assert {:error, duplicate} =
             as(system, fn -> Deployment.accept_release(project.key, release_attrs(@archive)) end)

    assert Exception.message(duplicate) =~ "already"

    # Custody in another project does not vouch for this one.
    assert {:error, refused} =
             as(system, fn ->
               Deployment.accept_release(project.key, release_attrs(@other_archive))
             end)

    assert Exception.message(refused) =~ "verify_artifact"

    assert {:ok, _} =
             as(system, fn ->
               Deployment.accept_release(other.key, release_attrs(@other_archive))
             end)

    # Malformed identity and untyped digests are refused before any custody lookup.
    assert {:error, _} =
             as(system, fn ->
               Deployment.accept_release(
                 project.key,
                 Map.put(release_attrs(@archive), :source_commit, "main")
               )
             end)

    assert {:error, _} =
             as(system, fn ->
               Deployment.accept_release(
                 project.key,
                 Map.put(release_attrs(@archive), :artifacts, %{tarball: "sha256:" <> @archive})
               )
             end)

    reader = actor("release-reader", :agent, [:reader])

    assert {:error, _} =
             as(reader, fn -> Deployment.accept_release(project.key, release_attrs(@archive)) end)

    assert {:error, %Postgrex.Error{postgres: %{message: "deployment_releases is immutable"}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "UPDATE deployment_releases SET source_commit = $1 WHERE id = $2::uuid",
               [@commit, Ecto.UUID.dump!(release.id)],
               mode: :savepoint
             )
  end

  # --- lifecycle, authorization, and execution ------------------------------------------

  test "a staging deployment is created, staged, authorized by a human, executed, verified, and replays with parity",
       %{system: system} do
    project = project_with_custody("path", @archive)
    approver = actor("path-approver", :human, [:approver])

    {:ok, release} =
      as(system, fn -> Deployment.accept_release(project.key, release_attrs(@archive)) end)

    assert {:ok, record} = as(system, fn -> Deployment.create(release.release_id, :staging) end)
    assert record.state == :queued
    refute record.requires_routing
    assert {:ok, record} = as(system, fn -> Deployment.stage(record.deployment_id) end)
    assert record.state == :staged

    assert {:ok, authorization} =
             as(approver, fn ->
               Deployment.authorize(record.deployment_id, %{
                 action: :execute_deploy,
                 approval_reference: "sop-ack-1"
               })
             end)

    assert authorization.approved_by == approver.name
    assert Authorization.unexpired?(authorization)

    assert {:ok, operation} =
             as(system, fn -> Deployment.request(authorization.authorization_id) end)

    assert operation.operation_id == Operation.deterministic_id(authorization.authorization_id)
    assert operation.phase == :requested
    assert operation.deployment.state == :deploying

    assert %Oban.Job{args: %{"operation_id" => queued}} =
             Repo.one!(from(job in Oban.Job, where: job.queue == "deployments"))

    assert queued == operation.operation_id

    # Spent is spent: the same authorization cannot request a second operation.
    assert {:error, :authorization_already_spent} =
             as(system, fn -> Deployment.request(authorization.authorization_id) end)

    executor = actor("path-executor", :agent, [:deployment_executor])

    assert {:ok, operation} =
             as(executor, fn ->
               Deployment.start_operation(operation.operation_id, executor.name)
             end)

    assert operation.phase == :started

    assert {:ok, operation} =
             as(executor, fn ->
               Deployment.complete_operation(operation.operation_id, :succeeded, %{
                 evidence_digest: String.duplicate("f", 64),
                 detail: "activated"
               })
             end)

    assert operation.outcome == :succeeded
    assert operation.deployment.state == :verifying

    assert {:ok, record} =
             as(system, fn ->
               Deployment.observe_health(record.deployment_id, :healthy, "probe ok")
             end)

    assert record.state == :ready
    assert record.health_status == :healthy
    assert record.terminal_at

    assert {:ok, :parity} = as(system, fn -> Deployment.parity(record.deployment_id) end)
    assert {:ok, projection} = Deployment.projection(record.deployment_id)
    assert projection.state == :ready
    assert projection.operations[operation.operation_id].source == "executor"

    assert {:ok, events} = Ledger.read(record.deployment_id)

    assert Enum.map(events, & &1.event_type) == [
             "DeploymentCreated",
             "DeploymentTransitioned",
             "DeploymentTransitioned",
             "DeploymentOperationRequested",
             "DeploymentTransitioned",
             "DeploymentOperationStarted",
             "DeploymentOperationCompleted",
             "DeploymentTransitioned",
             "DeploymentHealthObserved",
             "DeploymentTransitioned"
           ]

    requested = Enum.find(events, &(&1.event_type == "DeploymentOperationRequested"))
    assert requested.payload["approved_by"] == approver.name
    assert requested.payload["approval_reference"] == "sop-ack-1"
  end

  test "authorizations bind one human approval to one deployment, one action, and a bounded window",
       %{system: system} do
    {record, _release, project} = staged("authz", @archive, system)
    approver = actor("authz-approver", :human, [:approver])
    agent_approver = actor("authz-agent", :agent, [:approver])
    operator = actor("authz-operator", :human, [:operator])

    assert {:error, refused} =
             as(agent_approver, fn ->
               Deployment.authorize(record.deployment_id, %{
                 action: :execute_deploy,
                 approval_reference: "r"
               })
             end)

    assert Exception.message(refused) =~ "human"

    assert {:error, _} =
             as(operator, fn ->
               Deployment.authorize(record.deployment_id, %{
                 action: :execute_deploy,
                 approval_reference: "r"
               })
             end)

    assert {:error, refused} =
             as(approver, fn ->
               Deployment.authorize(record.deployment_id, %{
                 action: :execute_deploy,
                 approval_reference: ""
               })
             end)

    assert Exception.message(refused) =~ "approval_reference"

    assert {:error, refused} =
             as(approver, fn ->
               Deployment.authorize(record.deployment_id, %{
                 action: :execute_deploy,
                 approval_reference: "r",
                 ttl_seconds: 3_601
               })
             end)

    assert Exception.message(refused) =~ "exceeds"

    assert {:error, refused} =
             as(approver, fn ->
               Deployment.authorize(record.deployment_id, %{
                 action: :execute_rollback,
                 approval_reference: "r"
               })
             end)

    assert Exception.message(refused) =~ "target_deployment_id"

    assert {:error, _} =
             as(approver, fn ->
               Deployment.authorize(record.deployment_id, %{
                 action: :sudo,
                 approval_reference: "r"
               })
             end)

    # Immutable once issued.
    {:ok, authorization} =
      as(approver, fn ->
        Deployment.authorize(record.deployment_id, %{
          action: :execute_deploy,
          approval_reference: "r",
          ttl_seconds: 1
        })
      end)

    assert {:error,
            %Postgrex.Error{postgres: %{message: "deployment_authorizations is immutable"}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "UPDATE deployment_authorizations SET expires_at = now() + interval '1 hour' WHERE id = $1::uuid",
               [Ecto.UUID.dump!(authorization.id)],
               mode: :savepoint
             )

    Process.sleep(1_100)

    assert {:error, :authorization_expired} =
             as(system, fn -> Deployment.request(authorization.authorization_id) end)

    # An authorization for a rollback does not license a deploy, and a refused
    # request leaves the authorization unspent.
    {:ok, other} =
      as(system, fn -> Deployment.create(second_release(project, system).release_id, :staging) end)

    {:ok, wrong_action} =
      as(approver, fn ->
        Deployment.authorize(record.deployment_id, %{
          action: :execute_rollback,
          target_deployment_id: other.deployment_id,
          approval_reference: "r"
        })
      end)

    assert {:error, {:invalid_state_for_action, :staged}} =
             as(system, fn -> Deployment.request(wrong_action.authorization_id) end)

    assert Repo.aggregate(Operation, :count) == 0

    # A non-operator holding the authorization cannot request with it.
    {:ok, valid} =
      as(approver, fn ->
        Deployment.authorize(record.deployment_id, %{
          action: :execute_deploy,
          approval_reference: "r"
        })
      end)

    reader = actor("authz-reader", :agent, [:reader])
    assert {:error, _} = as(reader, fn -> Deployment.request(valid.authorization_id) end)
    assert Repo.aggregate(Operation, :count) == 0
  end

  test "production deployments require fresh routing evidence and refuse an unsafe boundary", %{
    system: system
  } do
    {record, _release, _project} = staged("routing", @archive, system, :production)
    assert record.requires_routing
    approver = actor("routing-approver", :human, [:approver])

    {:ok, authorization} =
      as(approver, fn ->
        Deployment.authorize(record.deployment_id, %{
          action: :execute_deploy,
          approval_reference: "r"
        })
      end)

    assert {:error, :routing_evidence_required} =
             as(system, fn -> Deployment.request(authorization.authorization_id) end)

    assert {:error, :invalid_routing_observation} =
             as(system, fn ->
               Deployment.request(authorization.authorization_id, routing: %{bogus: true})
             end)

    stale =
      put_in(
        routing(),
        [:observation, :observed_at],
        DateTime.add(DateTime.utc_now(), -3_600, :second)
      )

    assert {:error, {:routing_unsafe, reasons}} =
             as(system, fn ->
               Deployment.request(authorization.authorization_id, routing: stale)
             end)

    assert :observation_stale in reasons
    assert Repo.aggregate(Operation, :count) == 0

    assert {:ok, operation} =
             as(system, fn ->
               Deployment.request(authorization.authorization_id, routing: routing())
             end)

    assert operation.deployment.state == :deploying
    assert {:ok, [_, _, _, requested | _]} = Ledger.read(record.deployment_id)
    assert requested.payload["evidence"]["routing"] == "routing_ready"
  end

  test "cancellation needs a reason, stops before rollout, and is terminal", %{system: system} do
    {record, _release, _project} = staged("cancel", @archive, system)

    assert {:error, :invalid_cancellation_reason} =
             as(system, fn -> Deployment.cancel(record.deployment_id, "") end)

    assert {:ok, record} =
             as(system, fn -> Deployment.cancel(record.deployment_id, "operator stopped") end)

    assert record.state == :cancelled
    assert record.cancellation_reason == "operator stopped"

    assert {:error, :invalid_transition} =
             as(system, fn -> Deployment.stage(record.deployment_id) end)

    assert {:error, :invalid_transition} =
             as(system, fn -> Deployment.cancel(record.deployment_id, "again") end)

    assert {:error, {:invalid_state_for_action, :cancelled}} =
             as(system, fn -> Deployment.observe_health(record.deployment_id, :healthy, nil) end)

    ready = ready_deployment("cancel-ready", @other_archive, system)

    assert {:error, :invalid_transition} =
             as(system, fn -> Deployment.cancel(ready.deployment_id, "changed my mind") end)

    assert {:ok, :parity} = as(system, fn -> Deployment.parity(record.deployment_id) end)
  end

  test "rollback targets only a distinct ready release in the same project and environment", %{
    system: system
  } do
    good = ready_deployment("rb", @archive, system)

    good_release = Ash.get!(Release, good.release_id, authorize?: false)
    project = Ash.get!(Project, good_release.project_id, authorize?: false)

    {:ok, bad_release} =
      as(system, fn ->
        Deployment.accept_release(project.key, release_attrs(@archive, pipeline_number: 8))
      end)

    bad = ready_path(bad_release.release_id, :unhealthy, system)
    assert bad.state == :failed
    approver = actor("rb-approver", :human, [:approver])
    executor = actor("rb-executor", :agent, [:deployment_executor])

    refuse = fn target ->
      {:ok, authorization} =
        as(approver, fn ->
          Deployment.authorize(bad.deployment_id, %{
            action: :execute_rollback,
            target_deployment_id: target,
            approval_reference: "r"
          })
        end)

      as(system, fn -> Deployment.request(authorization.authorization_id) end)
    end

    assert {:error, :invalid_rollback_target} = refuse.("dpl-missing")
    assert {:error, :invalid_rollback_target} = refuse.(bad.deployment_id)

    {:ok, queued} = as(system, fn -> Deployment.create(bad_release.release_id, :staging) end)
    assert {:error, :invalid_rollback_target} = refuse.(queued.deployment_id)

    {:ok, other_env} = as(system, fn -> Deployment.create(good_release.release_id, :preview) end)
    assert {:error, :invalid_rollback_target} = refuse.(other_env.deployment_id)

    elsewhere = ready_deployment("rb-elsewhere", @other_archive, system)
    assert {:error, :invalid_rollback_target} = refuse.(elsewhere.deployment_id)

    {:ok, authorization} =
      as(approver, fn ->
        Deployment.authorize(bad.deployment_id, %{
          action: :execute_rollback,
          target_deployment_id: good.deployment_id,
          approval_reference: "r"
        })
      end)

    assert {:ok, operation} =
             as(system, fn -> Deployment.request(authorization.authorization_id) end)

    assert operation.deployment.state == :rolling_back
    assert operation.deployment.rollback_target_id == good.deployment_id

    {:ok, _} =
      as(executor, fn -> Deployment.start_operation(operation.operation_id, executor.name) end)

    {:ok, operation} =
      as(executor, fn ->
        Deployment.complete_operation(operation.operation_id, :succeeded, %{})
      end)

    assert operation.deployment.state == :rolled_back
    assert {:ok, :parity} = as(system, fn -> Deployment.parity(bad.deployment_id) end)
    assert {:ok, projection} = Deployment.projection(bad.deployment_id)
    assert projection.rollback_target.deployment_id == good.deployment_id
  end

  test "reclamation judges a preview against its live cohort and requires recovery evidence", %{
    system: system
  } do
    project = project_with_custody("reclaim", @archive)

    {:ok, release} =
      as(system, fn -> Deployment.accept_release(project.key, release_attrs(@archive)) end)

    approver = actor("reclaim-approver", :human, [:approver])
    executor = actor("reclaim-executor", :agent, [:deployment_executor])

    previews =
      for _ <- 1..4 do
        {:ok, record} = as(system, fn -> Deployment.create(release.release_id, :preview) end)

        {:ok, record} =
          as(system, fn -> Deployment.cancel(record.deployment_id, "preview finished") end)

        record
      end

    [subject | _] = previews

    Repo.query!(
      "UPDATE deployments SET terminal_at = now() - interval '30 days' WHERE deployment_id = $1",
      [subject.deployment_id]
    )

    authorize = fn ->
      as(approver, fn ->
        Deployment.authorize(subject.deployment_id, %{
          action: :execute_reclaim,
          approval_reference: "r"
        })
      end)
    end

    {:ok, unverified} = authorize.()

    assert {:error, :recovery_unverified} =
             as(system, fn -> Deployment.request(unverified.authorization_id) end)

    policy = %{recovery: %{restore_verified: true}}
    {:ok, authorization} = authorize.()

    assert {:ok, operation} =
             as(system, fn ->
               Deployment.request(authorization.authorization_id, policy: policy)
             end)

    assert operation.deployment.state == :cancelled

    {:ok, _} =
      as(executor, fn -> Deployment.start_operation(operation.operation_id, executor.name) end)

    {:ok, operation} =
      as(executor, fn ->
        Deployment.complete_operation(operation.operation_id, :succeeded, %{})
      end)

    assert operation.deployment.reclaimed_at

    {:ok, again} = authorize.()

    assert {:error, :already_reclaimed} =
             as(system, fn -> Deployment.request(again.authorization_id, policy: policy) end)

    # A recent preview is protected as one of the newest per project; a staging deployment is never reclaimable.
    [_, recent | _] = previews

    {:ok, protected} =
      as(approver, fn ->
        Deployment.authorize(recent.deployment_id, %{
          action: :execute_reclaim,
          approval_reference: "r"
        })
      end)

    assert {:error, :within_minimum_retained} =
             as(system, fn -> Deployment.request(protected.authorization_id, policy: policy) end)

    staging = ready_deployment("reclaim-staging", @other_archive, system)

    {:ok, wrong_env} =
      as(approver, fn ->
        Deployment.authorize(staging.deployment_id, %{
          action: :execute_reclaim,
          approval_reference: "r"
        })
      end)

    assert {:error, :not_a_preview_environment} =
             as(system, fn -> Deployment.request(wrong_env.authorization_id, policy: policy) end)
  end

  # --- executor ------------------------------------------------------------------------------

  test "the executor records started before acting and completes from the adapter receipt", %{
    system: system
  } do
    operation = requested_deploy("exec-ok", system)
    executor = configure_executor("exec-ok", SucceedingAdapter)

    assert :ok = Executor.perform(%Oban.Job{args: %{"operation_id" => operation.operation_id}})

    operation = Ash.get!(Operation, operation.id, authorize?: false)
    assert operation.phase == :completed
    assert operation.outcome == :succeeded
    assert operation.executor_id == executor.name
    assert operation.evidence_digest == String.duplicate("f", 64)
    assert Ash.get!(Record, operation.deployment_id, authorize?: false).state == :verifying

    assert {:discard, "operation already completed"} =
             Executor.perform(%Oban.Job{args: %{"operation_id" => operation.operation_id}})

    assert {:discard, "expected exactly one operation_id"} =
             Executor.perform(%Oban.Job{
               args: %{"operation_id" => operation.operation_id, "command" => "rm -rf /"}
             })
  end

  test "an adapter failure is a typed failed completion that fails the deployment closed", %{
    system: system
  } do
    operation = requested_deploy("exec-fail", system)
    configure_executor("exec-fail", FailingAdapter)

    assert :ok = Executor.perform(%Oban.Job{args: %{"operation_id" => operation.operation_id}})
    operation = Ash.get!(Operation, operation.id, authorize?: false)
    assert operation.outcome == :failed
    assert operation.detail == "systemctl restart failed"
    assert Ash.get!(Record, operation.deployment_id, authorize?: false).state == :failed
  end

  test "after a timeout the executor reconciles the host's observation before completing or retrying",
       %{system: system} do
    operation = requested_deploy("exec-timeout", system)
    configure_executor("exec-timeout", HangingAdapter)
    Application.put_env(:spruce_goose, :deployment_operation_timeout_ms, 50)

    Application.put_env(:spruce_goose, :test_host_observation, %{
      status: :in_progress,
      detail: "restarting"
    })

    assert {:error, reason} =
             Executor.perform(%Oban.Job{args: %{"operation_id" => operation.operation_id}})

    assert reason =~ "in_progress"

    operation = Ash.get!(Operation, operation.id, authorize?: false)
    assert operation.phase == :started
    assert operation.observation_count == 1

    # The retry does not execute again: it asks the host, and the host now confirms.
    Application.put_env(:spruce_goose, :test_host_observation, %{
      status: :succeeded,
      detail: "active"
    })

    assert :ok = Executor.perform(%Oban.Job{args: %{"operation_id" => operation.operation_id}})

    operation = Ash.get!(Operation, operation.id, authorize?: false)
    assert operation.phase == :completed
    assert operation.outcome == :succeeded
    assert operation.observation_count == 2

    {:ok, projection} =
      Deployment.projection(
        Ash.get!(Record, operation.deployment_id, authorize?: false).deployment_id
      )

    assert projection.operations[operation.operation_id].source == "observation"

    assert projection.operations[operation.operation_id].observations == [
             "in_progress",
             "succeeded"
           ]
  end

  test "the executor refuses to act without a configured, active executor actor and adapter", %{
    system: system
  } do
    operation = requested_deploy("exec-unconfigured", system)
    Application.delete_env(:spruce_goose, :deployment_executor_actor)

    assert {:discard, "deployment executor actor is not configured"} =
             Executor.perform(%Oban.Job{args: %{"operation_id" => operation.operation_id}})

    configure_executor("exec-unconfigured", nil)

    assert {:discard, "deployment host adapter is not configured"} =
             Executor.perform(%Oban.Job{args: %{"operation_id" => operation.operation_id}})

    assert Ash.get!(Operation, operation.id, authorize?: false).phase == :requested
  end

  # --- database invariants -------------------------------------------------------------

  test "PostgreSQL never deletes a deployment or operation and freezes their identity", %{
    system: system
  } do
    operation = requested_deploy("sql", system)

    assert {:error, %Postgrex.Error{postgres: %{message: "deployments rows are never deleted"}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "DELETE FROM deployments WHERE id = $1::uuid",
               [Ecto.UUID.dump!(operation.deployment_id)],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{message: "deployments identity is immutable"}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "UPDATE deployments SET environment = 'production' WHERE id = $1::uuid",
               [Ecto.UUID.dump!(operation.deployment_id)],
               mode: :savepoint
             )

    assert {:error,
            %Postgrex.Error{postgres: %{message: "deployment_operations identity is immutable"}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "UPDATE deployment_operations SET action = 'execute_reclaim' WHERE id = $1::uuid",
               [Ecto.UUID.dump!(operation.id)],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{postgres: %{constraint: "deployment_operation_phase_shape"}}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "UPDATE deployment_operations SET phase = 'completed' WHERE id = $1::uuid",
               [Ecto.UUID.dump!(operation.id)],
               mode: :savepoint
             )
  end

  # --- fixtures ----------------------------------------------------------------------------

  defp as(actor, fun), do: Authz.with_actor(actor, fun)

  defp actor(name, kind, roles) do
    actor = Ash.create!(Actor, %{name: name, kind: kind, created_by: "test"}, authorize?: false)

    for role <- roles,
        do:
          Ash.create!(Grant, %{actor_id: actor.id, role: role, scope: "*", granted_by: "test"},
            authorize?: false
          )

    actor
  end

  defp release_attrs(archive_hex, overrides \\ []) do
    Map.merge(
      %{
        forge_instance: "mama-forgejo",
        repository: "root/sprucegoose",
        source_commit: @commit,
        pipeline_number: 7,
        pipeline_digest: String.duplicate("c", 64),
        artifacts: %{archive: "sha256:" <> archive_hex}
      },
      Map.new(overrides)
    )
  end

  defp routing do
    now = DateTime.utc_now()

    %{
      observation: %{
        observed_at: now,
        hostname: "accounta.bot",
        resolved_addresses: ["178.156.142.163"],
        certificate: %{
          not_after: DateTime.add(now, 60 * 86_400, :second),
          sans: ["accounta.bot"],
          trusted: true
        },
        route: %{upstream: "127.0.0.1:17777", state: "active"},
        recovery: %{restore_verified: true, config_backup: "20260726T161116Z"}
      },
      expected: %{
        hostname: "accounta.bot",
        address: "178.156.142.163",
        upstream: "127.0.0.1:17777"
      }
    }
  end

  defp staged(suffix, archive_hex, system, environment \\ :staging) do
    project = project_with_custody(suffix, archive_hex)

    {:ok, release} =
      as(system, fn -> Deployment.accept_release(project.key, release_attrs(archive_hex)) end)

    {:ok, record} = as(system, fn -> Deployment.create(release.release_id, environment) end)
    {:ok, record} = as(system, fn -> Deployment.stage(record.deployment_id) end)
    {record, release, project}
  end

  defp second_release(project, system) do
    {:ok, release} =
      as(system, fn ->
        Deployment.accept_release(project.key, release_attrs(@archive, pipeline_number: 9))
      end)

    release
  end

  defp ready_deployment(suffix, archive_hex, system) do
    {_record, release, _project} = staged(suffix, archive_hex, system)
    ready_path(release.release_id, :healthy, system)
  end

  # Drives a fresh deployment of `release_id` through execution to a verified outcome.
  defp ready_path(release_id, health, system) do
    n = System.unique_integer([:positive])
    approver = actor("approver-#{n}", :human, [:approver])
    executor = actor("executor-#{n}", :agent, [:deployment_executor])

    {:ok, record} = as(system, fn -> Deployment.create(release_id, :staging) end)
    {:ok, record} = as(system, fn -> Deployment.stage(record.deployment_id) end)

    {:ok, authorization} =
      as(approver, fn ->
        Deployment.authorize(record.deployment_id, %{
          action: :execute_deploy,
          approval_reference: "r"
        })
      end)

    {:ok, operation} = as(system, fn -> Deployment.request(authorization.authorization_id) end)

    {:ok, _} =
      as(executor, fn -> Deployment.start_operation(operation.operation_id, executor.name) end)

    {:ok, _} =
      as(executor, fn ->
        Deployment.complete_operation(operation.operation_id, :succeeded, %{})
      end)

    {:ok, record} =
      as(system, fn -> Deployment.observe_health(record.deployment_id, health, "probe") end)

    record
  end

  defp requested_deploy(suffix, system) do
    {record, _release, _project} = staged(suffix, @archive, system)
    approver = actor("#{suffix}-approver", :human, [:approver])

    {:ok, authorization} =
      as(approver, fn ->
        Deployment.authorize(record.deployment_id, %{
          action: :execute_deploy,
          approval_reference: "r"
        })
      end)

    {:ok, operation} = as(system, fn -> Deployment.request(authorization.authorization_id) end)
    operation
  end

  defp configure_executor(suffix, adapter) do
    executor = actor("#{suffix}-executor", :agent, [:deployment_executor])
    Application.put_env(:spruce_goose, :deployment_executor_actor, executor.name)
    Application.put_env(:spruce_goose, :deployment_host_adapter, adapter)
    executor
  end

  # A project whose in-progress task carries a succeeded verify_artifact receipt
  # for `archive_hex`: the custody evidence release acceptance demands.
  defp project_with_custody(suffix, archive_hex) do
    {:ok, definition} = Definition.parse(%{tasks: [%{id: "deploy-#{suffix}", kind: :oban}]})
    project = Ash.create!(Project, %{key: "deploy-#{suffix}", name: "Deploy #{suffix}"})

    roadmap =
      Ash.create!(Roadmap, %{
        project_id: project.id,
        key: "deploy-#{suffix}",
        name: "Deploy #{suffix}"
      })

    workflow =
      Ash.create!(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: "deploy-#{suffix}",
        name: "Deploy #{suffix}",
        definition: definition
      })

    task =
      Ash.create!(Task, %{
        workflow_id: workflow.id,
        task_id: SpruceGoose.TaskId.generate(),
        title: "Deploy #{suffix}",
        definition_of_done: "verified",
        runner: :oban
      })

    task =
      Enum.reduce(
        [:proposed, :queued, :ready, :in_progress],
        task,
        &Ash.update!(&2, %{to_state: &1}, action: :transition)
      )

    permit =
      Ash.create!(
        Permit,
        %{
          task_id: task.id,
          source_event_id: "forgejo:1:#{suffix}",
          forge_instance: "mama-forgejo",
          repository: "root/sprucegoose",
          commit_sha: @commit,
          tree_sha: String.duplicate("b", 40),
          ref: "refs/heads/main",
          pipeline_digest: String.duplicate("c", 64),
          roots: @roots,
          action: :verify_artifact,
          input_artifact_digest: archive_hex
        },
        action: :admit,
        authorize?: false
      )

    Ash.create!(
      OutcomeReceipt,
      %{
        task_id: task.id,
        receipt_id:
          "drr-" <>
            String.duplicate("d", 60) <>
            String.pad_leading(Integer.to_string(System.unique_integer([:positive]), 16), 4, "0"),
        permit_id: permit.permit_id,
        executor_id: "verifier",
        outcome: :succeeded,
        evidence_digest: String.duplicate("e", 64),
        artifact_digest: archive_hex,
        roots: @roots
      },
      action: :record,
      authorize?: false
    )

    project
  end
end
