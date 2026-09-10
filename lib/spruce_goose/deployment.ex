defmodule SpruceGoose.Deployment do
  @moduledoc """
  The deployment domain: release acceptance, deployment lifecycle, execution
  authorization, and execution tracking, with one authoritative record per
  deployment and one linked certified event stream behind it.

  Every mutation runs as the request's actor, under a per-deployment advisory
  lock, in one transaction that updates the projection row and appends the
  event licensing that update. A refused step rolls the whole transaction
  back, so an authorization is spent only by a request that was accepted in
  full: consumption, operation identity, and queued work commit together.

  Nothing here touches a host. Effects are performed by
  `SpruceGoose.Deployment.Executor` through a `HostAdapter`, and only after an
  operation has been recorded as requested.
  """

  alias SpruceGoose.{Authz, Repo}

  alias SpruceGoose.Deployment.{
    Authorization,
    Executor,
    Ledger,
    Lifecycle,
    Operation,
    Record,
    Release,
    ReleaseIdentity,
    Retention,
    Routing
  }

  alias SpruceGoose.Workflows.Project

  @rollback_sources [:ready, :failed, :deploying, :verifying]

  # --- releases ---------------------------------------------------------------

  @doc "Accept a release into a project on the strength of its verified artifact custody."
  def accept_release(project_key, attrs) when is_map(attrs) do
    with {:ok, project} <- Authz.read_one(Project, key: project_key) do
      Authz.create(Release, Map.put(attrs, :project_id, project.id), action: :accept)
    end
  end

  # --- lifecycle bookkeeping ----------------------------------------------------

  @doc "Create a queued deployment of an accepted release into an environment."
  def create(release_id, environment, opts \\ []) do
    with {:ok, release} <- Authz.read_one(Release, release_id: release_id),
         {:ok, project} <- Authz.read_one(Project, id: release.project_id),
         {:ok, identity} <- Release.identity(release) do
      transaction(fn ->
        input = %{
          release_id: release.id,
          environment: environment,
          pinned: Keyword.get(opts, :pinned, false)
        }

        with {:ok, record, _} <- Authz.create_with_notifications(Record, input),
             {:ok, head} <-
               Ledger.append(
                 record.deployment_id,
                 "DeploymentCreated",
                 %{
                   "project" => project.key,
                   "environment" => Atom.to_string(record.environment),
                   "release" => ReleaseIdentity.to_map(identity),
                   "release_id" => release.release_id,
                   "requires_routing" => record.requires_routing
                 },
                 nil
               ) do
          project_row(record, %{last_event: head})
        end
      end)
    end
  end

  @doc "Record build acceptance: queued -> building -> staged."
  def stage(deployment_id) do
    mutate(deployment_id, fn record ->
      with {:ok, record} <- transition(record, :building), do: transition(record, :staged)
    end)
  end

  @doc "Cancel a deployment that has not rolled out. Requires a reason."
  def cancel(deployment_id, reason) when is_binary(reason) and reason != "" do
    mutate(deployment_id, fn record ->
      with {:ok, :cancelled} <- Lifecycle.transition(record.state, :cancelled),
           {:ok, head} <-
             Ledger.append(
               record.deployment_id,
               "DeploymentCancellationRequested",
               %{"reason" => reason},
               record.last_event
             ),
           {:ok, record} <- project_row(record, %{cancellation_reason: reason, last_event: head}) do
        transition(record, :cancelled)
      end
    end)
  end

  def cancel(_, _), do: {:error, :invalid_cancellation_reason}

  @doc "Record a verification outcome: healthy promotes to ready, unhealthy fails closed."
  def observe_health(deployment_id, status, detail) when status in [:healthy, :unhealthy] do
    mutate(deployment_id, fn record ->
      with :ok <- require_state(record, [:verifying]),
           {:ok, head} <-
             Ledger.append(
               record.deployment_id,
               "DeploymentHealthObserved",
               %{"status" => Atom.to_string(status), "detail" => detail},
               record.last_event
             ),
           {:ok, record} <-
             project_row(record, %{health_status: status, health_detail: detail, last_event: head}) do
        transition(record, if(status == :healthy, do: :ready, else: :failed))
      end
    end)
  end

  def observe_health(_, _, _), do: {:error, :invalid_verification_status}

  # --- authorization and execution requests ---------------------------------------

  @doc "Issue a single-use approval for one effect on one deployment. Approver must be human."
  def authorize(deployment_id, attrs) when is_map(attrs) do
    with {:ok, record} <- Authz.read_one(Record, deployment_id: deployment_id) do
      Authz.create(Authorization, Map.put(attrs, :deployment_id, record.id), action: :issue)
    end
  end

  @doc """
  Spend an authorization: re-validate every precondition against live state,
  record the operation, append the request event, advance the lifecycle, and
  queue the executor, all in one transaction.

  Options: `routing: %{observation: map, expected: map}` (required for
  deployments that require routing), `policy: map` (retention policy with
  recovery evidence, for reclaim).
  """
  def request(authorization_id, opts \\ []) do
    with {:ok, authorization} <- Authz.read_one(Authorization, authorization_id: authorization_id),
         {:ok, record} <- Authz.read_one(Record, id: authorization.deployment_id) do
      mutate(record.deployment_id, fn record ->
        with :ok <- require_unexpired(authorization),
             :ok <- require_unspent(authorization),
             {:ok, evidence} <- preconditions(authorization, record, opts),
             {:ok, operation} <- spend(authorization, record),
             {:ok, head} <-
               Ledger.append(
                 record.deployment_id,
                 "DeploymentOperationRequested",
                 %{
                   "operation_id" => operation.operation_id,
                   "action" => Atom.to_string(authorization.action),
                   "authorization_id" => authorization.authorization_id,
                   "approved_by" => authorization.approved_by,
                   "approval_reference" => authorization.approval_reference,
                   "target_deployment_id" => authorization.target_deployment_id,
                   "evidence" => evidence
                 },
                 record.last_event
               ),
             {:ok, record} <- project_row(record, %{last_event: head}),
             {:ok, record} <- after_request(authorization, record, evidence),
             {:ok, _job} <-
               %{operation_id: operation.operation_id} |> Executor.new() |> Oban.insert() do
          {:ok, %{operation | deployment: record}}
        end
      end)
    end
  end

  # --- executor-facing receipts -------------------------------------------------------

  @doc "Record that an executor has begun the operation on the host."
  def start_operation(operation_id, executor_id) do
    with_operation(operation_id, fn operation, record ->
      with {:ok, operation, _} <-
             Authz.update_with_notifications(operation, %{executor_id: executor_id},
               action: :start
             ),
           {:ok, head} <-
             Ledger.append(
               record.deployment_id,
               "DeploymentOperationStarted",
               %{"operation_id" => operation_id, "executor_id" => executor_id},
               record.last_event
             ),
           {:ok, record} <- project_row(record, %{last_event: head}) do
        {:ok, %{operation | deployment: record}}
      end
    end)
  end

  @doc "Record the completion of an operation and advance the lifecycle accordingly."
  def complete_operation(operation_id, outcome, attrs \\ %{})
      when outcome in [:succeeded, :failed] do
    with_operation(operation_id, fn operation, record ->
      input = %{
        outcome: outcome,
        evidence_digest: attrs[:evidence_digest],
        detail: attrs[:detail]
      }

      with {:ok, operation, _} <-
             Authz.update_with_notifications(operation, input, action: :complete),
           {:ok, head} <-
             Ledger.append(
               record.deployment_id,
               "DeploymentOperationCompleted",
               %{
                 "operation_id" => operation_id,
                 "outcome" => Atom.to_string(outcome),
                 "evidence_digest" => attrs[:evidence_digest],
                 "detail" => attrs[:detail],
                 "source" => Map.get(attrs, :source, "executor")
               },
               record.last_event
             ),
           {:ok, record} <- project_row(record, %{last_event: head}),
           {:ok, record} <- after_completion(operation, record) do
        {:ok, %{operation | deployment: record}}
      end
    end)
  end

  @doc "Record what host inspection observed about a started operation."
  def observe_operation(operation_id, status, detail) when is_atom(status) do
    with_operation(operation_id, fn operation, record ->
      with {:ok, operation, _} <-
             Authz.update_with_notifications(operation, %{detail: detail}, action: :observe),
           {:ok, head} <-
             Ledger.append(
               record.deployment_id,
               "DeploymentOperationObserved",
               %{
                 "operation_id" => operation_id,
                 "status" => Atom.to_string(status),
                 "detail" => detail
               },
               record.last_event
             ),
           {:ok, record} <- project_row(record, %{last_event: head}) do
        {:ok, %{operation | deployment: record}}
      end
    end)
  end

  @doc "The identity-only request an adapter receives for an operation."
  def operation_request(%Operation{} = operation) do
    with {:ok, record} <- Authz.read_one(Record, id: operation.deployment_id),
         {:ok, release} <- release_map(record),
         {:ok, target} <- target_map(operation.target_deployment_id) do
      {:ok,
       %{
         operation_id: operation.operation_id,
         action: operation.action,
         deployment_id: record.deployment_id,
         environment: record.environment,
         release: release,
         target: target
       }}
    end
  end

  # --- reads --------------------------------------------------------------------------------

  @doc "The projection replayed from the certified stream alone."
  def projection(deployment_id), do: Ledger.project(deployment_id)

  @doc "Does the authoritative row agree with its replayed stream?"
  def parity(deployment_id) do
    with {:ok, record} <- Authz.read_one(Record, deployment_id: deployment_id),
         {:ok, projection} <- projection(deployment_id) do
      mismatches =
        [
          {:state, record.state, projection.state},
          {:health, record.health_status, projection.health.status},
          {:cancellation_reason, record.cancellation_reason, projection.cancellation_reason},
          {:rollback_target, record.rollback_target_id,
           projection.rollback_target && projection.rollback_target.deployment_id},
          {:head, record.last_event, projection.last_identity}
        ]
        |> Enum.reject(fn {_, row, replayed} -> row == replayed end)

      if mismatches == [], do: {:ok, :parity}, else: {:error, {:parity_mismatch, mismatches}}
    end
  end

  # --- internals ----------------------------------------------------------------------------

  defp transaction(fun) do
    # AUTHORIZATION: every write inside runs through Authz as the request's actor.
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, value} -> value
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mutate(deployment_id, fun) do
    transaction(fn ->
      # AUTHORIZATION: the actor-bound read below is the first data access; the lock only serializes this deployment.
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [deployment_id])

      with {:ok, record} <- Authz.read_one(Record, deployment_id: deployment_id), do: fun.(record)
    end)
  end

  defp with_operation(operation_id, fun) do
    with {:ok, operation} <- Authz.read_one(Operation, operation_id: operation_id),
         {:ok, record} <- Authz.read_one(Record, id: operation.deployment_id) do
      mutate(record.deployment_id, fn record ->
        with {:ok, operation} <- Authz.read_one(Operation, operation_id: operation_id),
             do: fun.(operation, record)
      end)
    end
  end

  defp transition(record, to) do
    with {:ok, ^to} <- Lifecycle.transition(record.state, to),
         {:ok, head} <-
           Ledger.append(
             record.deployment_id,
             "DeploymentTransitioned",
             %{"state" => Atom.to_string(to)},
             record.last_event
           ) do
      terminal_at =
        if Lifecycle.terminal?(to) and is_nil(record.terminal_at), do: DateTime.utc_now()

      project_row(record, %{
        state: to,
        last_event: head,
        terminal_at: terminal_at || record.terminal_at
      })
    end
  end

  defp project_row(record, attrs) do
    with {:ok, record, _} <- Authz.update_with_notifications(record, attrs, action: :project),
         do: {:ok, record}
  end

  defp require_state(%{state: state}, allowed) do
    if state in allowed, do: :ok, else: {:error, {:invalid_state_for_action, state}}
  end

  defp require_environment(%{environment: environment}, environment, _reason), do: :ok
  defp require_environment(_record, _environment, reason), do: {:error, reason}

  defp require_unexpired(authorization) do
    if Authorization.unexpired?(authorization), do: :ok, else: {:error, :authorization_expired}
  end

  # Reported before preconditions so a spent authorization is named as such
  # rather than as whatever state its own operation left the deployment in.
  # The unique index in spend/2 remains the guard against a concurrent spender.
  defp require_unspent(authorization) do
    case Authz.read_one(Operation, authorization_id: authorization.authorization_id) do
      {:ok, %Operation{}} -> {:error, :authorization_already_spent}
      _ -> :ok
    end
  end

  # The one row that spends the authorization. Uniqueness on authorization_id is
  # the single-use invariant; a second spender sees the conflict, never a second operation.
  defp spend(authorization, record) do
    input = %{
      deployment_id: record.id,
      authorization_id: authorization.authorization_id,
      action: authorization.action,
      target_deployment_id: authorization.target_deployment_id
    }

    case Authz.create_with_notifications(Operation, input, action: :request) do
      {:ok, operation, _} ->
        {:ok, operation}

      {:error, error} ->
        {:error,
         if(Exception.message(error) =~ "already", do: :authorization_already_spent, else: error)}
    end
  end

  defp preconditions(%{action: :execute_deploy}, record, opts) do
    with :ok <- require_state(record, [:staged]),
         do: routing_evidence(record, Keyword.get(opts, :routing))
  end

  defp preconditions(%{action: :execute_rollback} = authorization, record, _opts) do
    with :ok <- require_state(record, @rollback_sources),
         {:ok, target} <- rollback_target(record, authorization.target_deployment_id) do
      {:ok,
       %{
         "target_deployment_id" => target.deployment_id,
         "target_release_id" => target.release.release_id
       }}
    end
  end

  defp preconditions(%{action: :execute_reclaim}, record, opts) do
    policy = Keyword.get(opts, :policy, %{})

    with :ok <- require_environment(record, :preview, :not_a_preview_environment),
         :ok <- if(is_nil(record.reclaimed_at), do: :ok, else: {:error, :already_reclaimed}),
         {:ok, cohort} <- preview_cohort(record),
         subject <- Enum.find(cohort, &(&1.id == record.deployment_id)),
         :ok <- Retention.assert_reclaimable(subject, cohort, policy) do
      {:ok, %{"cohort_size" => length(cohort), "recovery" => "restore_verified"}}
    end
  end

  # Routing evidence is required whenever the deployment requires it; an omitted
  # observation is a refusal there, never a pass. Where it is not required, a
  # supplied observation is still evaluated rather than ignored.
  defp routing_evidence(%{requires_routing: true}, nil), do: {:error, :routing_evidence_required}
  defp routing_evidence(_record, nil), do: {:ok, nil}

  defp routing_evidence(_record, %{observation: observation, expected: expected}) do
    case Routing.evaluate(observation, expected) do
      {:ok, :routing_ready} ->
        {:ok,
         %{
           "routing" => "routing_ready",
           "hostname" => expected[:hostname],
           "upstream" => expected[:upstream]
         }}

      {:error, reasons} ->
        {:error, {:routing_unsafe, reasons}}
    end
  end

  defp routing_evidence(_record, _), do: {:error, :invalid_routing_observation}

  defp rollback_target(record, target_id) do
    with true <- is_binary(target_id) and target_id != record.deployment_id,
         {:ok, target} <- Authz.read_one(Record, deployment_id: target_id),
         {:ok, target} <- Ash.load(target, :release, actor: Authz.actor!(), authorize?: true),
         {:ok, source} <- Ash.load(record, :release, actor: Authz.actor!(), authorize?: true),
         true <- target.release.project_id == source.release.project_id,
         true <- target.environment == record.environment,
         true <- target.state == :ready,
         true <- target.release_id != record.release_id do
      {:ok, target}
    else
      _ -> {:error, :invalid_rollback_target}
    end
  end

  defp preview_cohort(record) do
    with {:ok, record} <-
           Ash.load(record, [release: :project], actor: Authz.actor!(), authorize?: true),
         {:ok, previews} <-
           Record
           |> Ash.Query.filter_input(
             environment: :preview,
             release: [project_id: record.release.project_id]
           )
           |> Authz.read() do
      {:ok, Enum.map(previews, &Record.to_retention(&1, record.release.project.key, 0))}
    end
  end

  defp after_request(%{action: :execute_deploy}, record, _evidence),
    do: transition(record, :deploying)

  defp after_request(%{action: :execute_rollback}, record, evidence) do
    with {:ok, head} <-
           Ledger.append(
             record.deployment_id,
             "DeploymentRollbackRequested",
             evidence,
             record.last_event
           ),
         {:ok, record} <-
           project_row(record, %{
             rollback_target_id: evidence["target_deployment_id"],
             last_event: head
           }) do
      transition(record, :rolling_back)
    end
  end

  defp after_request(%{action: :execute_reclaim}, record, _evidence), do: {:ok, record}

  defp after_completion(%{action: :execute_deploy, outcome: :succeeded}, record),
    do: transition(record, :verifying)

  defp after_completion(%{action: :execute_rollback, outcome: :succeeded}, record),
    do: transition(record, :rolled_back)

  defp after_completion(%{action: :execute_reclaim, outcome: :succeeded}, record),
    do: project_row(record, %{reclaimed_at: DateTime.utc_now()})

  defp after_completion(%{action: :execute_reclaim}, record), do: {:ok, record}
  defp after_completion(%{outcome: :failed}, record), do: transition(record, :failed)

  defp release_map(record) do
    with {:ok, release} <- Authz.read_one(Release, id: record.release_id),
         {:ok, identity} <- Release.identity(release) do
      {:ok, Map.put(ReleaseIdentity.to_map(identity), "release_id", release.release_id)}
    end
  end

  defp target_map(nil), do: {:ok, nil}

  defp target_map(target_id) do
    with {:ok, target} <- Authz.read_one(Record, deployment_id: target_id),
         {:ok, release} <- release_map(target) do
      {:ok, %{deployment_id: target.deployment_id, release: release}}
    end
  end
end
