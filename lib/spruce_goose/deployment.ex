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
          project_id: release.project_id,
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

  @doc """
  Record a verification outcome: healthy promotes to ready, unhealthy fails
  closed. `source` names who observed it: `"adapter"` for a host probe,
  `"operator"` for an assertion. The ledger keeps the distinction.
  """
  def observe_health(deployment_id, status, detail, source \\ "operator")

  def observe_health(deployment_id, status, detail, source)
      when status in [:healthy, :unhealthy] and source in ["operator", "adapter"] do
    mutate(deployment_id, fn record ->
      with :ok <- require_admitted(record, :health),
           {:ok, head} <-
             Ledger.append(
               record.deployment_id,
               "DeploymentHealthObserved",
               %{"status" => Atom.to_string(status), "detail" => detail, "source" => source},
               record.last_event
             ),
           {:ok, record} <-
             project_row(record, %{
               health_status: status,
               health_detail: detail,
               health_source: source,
               last_event: head
             }) do
        transition(record, if(status == :healthy, do: :ready, else: :failed))
      end
    end)
  end

  def observe_health(_, _, _, _), do: {:error, :invalid_verification_status}

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
             :ok <- require_no_open_operation(record),
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

  @doc """
  Record the completion of an operation and advance the lifecycle accordingly.

  Completion is total: the host's outcome is recorded even when the lifecycle
  cannot move on it, in which case a `DeploymentTransitionRefused` event names
  the step that was refused and the state stays where it was.
  """
  def complete_operation(operation_id, outcome, attrs \\ %{})
      when outcome in [:succeeded, :failed],
      do: record_completion(operation_id, outcome, attrs, :complete)

  @doc """
  The operator exit for an operation the executor could not conclude.

  Records the fresh host observation, then completes the operation as failed
  with source `operator`. Refused when the host reports success: that is a
  reconcile, not an abandonment. Requires `approver`.
  """
  def abandon_operation(operation_id, reason, %{status: status} = observation)
      when is_binary(reason) and reason != "" do
    with :ok <- if(status == :succeeded, do: {:error, :host_reports_success}, else: :ok),
         {:ok, _} <- observe_operation(operation_id, status, observation[:detail]) do
      record_completion(operation_id, :failed, %{detail: reason, source: "operator"}, :abandon)
    end
  end

  def abandon_operation(_, _, _), do: {:error, :invalid_abandonment}

  defp record_completion(operation_id, outcome, attrs, action) do
    with_operation(operation_id, fn operation, record ->
      input =
        case action do
          :abandon ->
            %{detail: attrs[:detail]}

          :complete ->
            %{outcome: outcome, evidence_digest: attrs[:evidence_digest], detail: attrs[:detail]}
        end

      with {:ok, operation, _} <-
             Authz.update_with_notifications(operation, input, action: action),
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

  @doc "The deployment whose release is live in `environment`, if any."
  def active(project_key, environment) do
    with {:ok, project} <- Authz.read_one(Project, key: project_key) do
      Record
      |> Ash.Query.filter_input(project_id: project.id, environment: environment, active: true)
      |> Authz.read()
      |> case do
        {:ok, [record]} -> {:ok, record}
        {:ok, []} -> {:ok, nil}
        error -> error
      end
    end
  end

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
          {:health_source, record.health_source, projection.health.source},
          {:active, record.active, projection.active},
          {:superseded_by, record.superseded_by, projection.superseded_by},
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

  # Two locks, always in this order: the environment first, because activation
  # touches two deployments of one environment and a fixed order is what keeps
  # concurrent mutations from deadlocking; then the deployment itself.
  defp mutate(deployment_id, fun) do
    transaction(fn ->
      with {:ok, record} <- Authz.read_one(Record, deployment_id: deployment_id) do
        lock(environment_key(record))
        lock(deployment_id)
        # Re-read under the locks: the first read only located the environment.
        with {:ok, record} <- Authz.read_one(Record, deployment_id: deployment_id),
             do: fun.(record)
      end
    end)
  end

  defp lock(key) do
    # AUTHORIZATION: the actor-bound read in mutate/2 precedes this; the lock only serializes writers.
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [key])
  end

  defp environment_key(record), do: "environment:#{record.project_id}:#{record.environment}"

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

      with {:ok, record} <-
             project_row(record, %{
               state: to,
               last_event: head,
               terminal_at: terminal_at || record.terminal_at
             }) do
        if to == :ready, do: activate(record, "ready"), else: {:ok, record}
      end
    end
  end

  # Move the environment's live-release pointer to `record`. The deployment it
  # displaces is told so on its own stream; a pointer already on `record` moves
  # nothing. Runs under the environment lock taken in mutate/2.
  defp activate(record, cause) do
    with {:ok, current} <- current_active(record),
         {:ok, _} <- supersede(current, record, cause) do
      if current && current.id == record.id do
        {:ok, record}
      else
        with {:ok, head} <-
               Ledger.append(
                 record.deployment_id,
                 "DeploymentActivated",
                 %{"cause" => cause, "supersedes" => current && current.deployment_id},
                 record.last_event
               ),
             do:
               project_row(record, %{
                 active: true,
                 superseded_at: nil,
                 superseded_by: nil,
                 last_event: head
               })
      end
    end
  end

  defp current_active(record) do
    Record
    |> Ash.Query.filter_input(
      project_id: record.project_id,
      environment: record.environment,
      active: true
    )
    |> Authz.read()
    |> case do
      {:ok, [current]} -> {:ok, current}
      {:ok, []} -> {:ok, nil}
      error -> error
    end
  end

  defp supersede(nil, _successor, _cause), do: {:ok, nil}
  defp supersede(%{id: id}, %{id: id}, _cause), do: {:ok, nil}

  defp supersede(current, successor, cause) do
    with {:ok, head} <-
           Ledger.append(
             current.deployment_id,
             "DeploymentSuperseded",
             %{"by" => successor.deployment_id, "cause" => cause},
             current.last_event
           ),
         do:
           project_row(current, %{
             active: false,
             superseded_at: DateTime.utc_now(),
             superseded_by: successor.deployment_id,
             last_event: head
           })
  end

  defp project_row(record, attrs) do
    with {:ok, record, _} <- Authz.update_with_notifications(record, attrs, action: :project),
         do: {:ok, record}
  end

  defp require_admitted(%{state: state, environment: environment}, event) do
    if Lifecycle.admits?(state, environment, event),
      do: :ok,
      else: {:error, {:invalid_state_for_action, state}}
  end

  # One open operation per deployment. Without this, a second request could
  # move the lifecycle out from under an operation still running on the host.
  defp require_no_open_operation(record) do
    open =
      Operation
      |> Ash.Query.filter_input(deployment_id: record.id, phase: [in: [:requested, :started]])
      |> Authz.count()

    case open do
      {:ok, 0} -> :ok
      {:ok, _} -> {:error, :operation_in_flight}
      {:error, reason} -> {:error, reason}
    end
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
    with :ok <- require_admitted(record, {:operation, :execute_deploy}),
         do: routing_evidence(record, Keyword.get(opts, :routing))
  end

  defp preconditions(%{action: :execute_rollback} = authorization, record, _opts) do
    with :ok <- require_admitted(record, {:operation, :execute_rollback}),
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

  defp after_completion(%{action: :execute_reclaim, outcome: :succeeded}, record),
    do: project_row(record, %{reclaimed_at: DateTime.utc_now()})

  defp after_completion(%{action: :execute_reclaim}, record), do: {:ok, record}

  defp after_completion(%{action: :execute_rollback, outcome: :succeeded} = operation, record) do
    with {:ok, record} <- transition_or_refuse(record, :rolled_back, operation.operation_id),
         {:ok, target} <- Authz.read_one(Record, deployment_id: record.rollback_target_id),
         :ok <- require_admitted(target, :activate),
         {:ok, _target} <- activate(target, "rollback") do
      # The pointer moved to the target; this record's own view of `active` is stale.
      Authz.read_one(Record, deployment_id: record.deployment_id)
    end
  end

  defp after_completion(operation, record),
    do: transition_or_refuse(record, lifecycle_after(operation), operation.operation_id)

  defp lifecycle_after(%{outcome: :failed}), do: :failed
  defp lifecycle_after(%{action: :execute_deploy}), do: :verifying
  defp lifecycle_after(%{action: :execute_rollback}), do: :rolled_back

  # Evidence of what the host did must never depend on the lifecycle's
  # willingness to move; a refused step is itself recorded.
  defp transition_or_refuse(record, to, operation_id) do
    case Lifecycle.transition(record.state, to) do
      {:ok, ^to} ->
        transition(record, to)

      {:error, :invalid_transition} ->
        with {:ok, head} <-
               Ledger.append(
                 record.deployment_id,
                 "DeploymentTransitionRefused",
                 %{
                   "operation_id" => operation_id,
                   "from" => Atom.to_string(record.state),
                   "to" => Atom.to_string(to)
                 },
                 record.last_event
               ),
             do: project_row(record, %{last_event: head})
    end
  end

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
