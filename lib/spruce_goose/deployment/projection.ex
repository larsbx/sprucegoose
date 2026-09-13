defmodule SpruceGoose.Deployment.Projection do
  @moduledoc """
  Fail-closed read model built solely by replaying one deployment's certified events.

  Every event on a `deployment:<id>` stream carries the content identity of the
  event before it in `payload["previous"]`. Replay checks that link, the
  lifecycle contract, and the operation phase order, and refuses at the first
  event that breaks any of them. A projection is therefore never rendered from
  a history with a gap, a fork, or an illegal step in it.

  Event names distinguish what was *requested*, what an executor *started*,
  what it reported as *completed*, and what host inspection *observed*. A
  deploy is not "executed" until the completion is recorded, and completion is
  attributed to its source.
  """

  alias SpruceGoose.Deployment.{Lifecycle, ReleaseIdentity}
  alias SpruceGoose.Kernel.CertifiedEvent

  @schema "sprucegoose-deployment-event-v1"
  @operation_actions [:execute_deploy, :execute_rollback, :execute_reclaim]
  @health ["healthy", "unhealthy", "unknown"]
  @max_reason 1_024

  def schema, do: @schema
  def operation_actions, do: @operation_actions

  @doc "Reduce an ordered event list into `{:ok, projection}` or the first refusal."
  def reduce(events) when is_list(events) do
    events
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, nil}, fn {event, position}, {:ok, acc} ->
      case apply_event(event, position, acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp apply_event(%CertifiedEvent{} = event, position, projection) do
    with :ok <- check_link(event, projection),
         :ok <- check_transient(event, projection),
         {:ok, next} <- step(event.event_type, event.payload, projection) do
      {:ok, %{next | last_identity: event.identity.digest, event_count: position}}
    else
      {:error, reason} -> {:error, {:invalid_event, position, reason}}
    end
  end

  defp apply_event(_event, position, _projection),
    do: {:error, {:invalid_event, position, :not_certified}}

  defp check_link(%{payload: %{"schema" => @schema, "previous" => previous}}, projection) do
    expected = if projection, do: projection.last_identity, else: nil
    if previous == expected, do: :ok, else: {:error, :broken_chain}
  end

  defp check_link(_, _), do: {:error, :unlinked_event}

  # A transient state admits exactly one successor and nothing else in between.
  defp check_transient(_event, nil), do: :ok

  defp check_transient(%{event_type: type, payload: payload}, %{state: state}) do
    if Lifecycle.transient?(state) and
         not (type == "DeploymentTransitioned" and payload["state"] == "staged"),
       do: {:error, :transient_state_escaped},
       else: :ok
  end

  defp admitted(projection, event) do
    if Lifecycle.admits?(projection.state, projection.environment, event),
      do: :ok,
      else: {:error, :not_admitted}
  end

  defp no_open_operation(projection) do
    if Enum.all?(projection.operations, fn {_id, op} -> op.phase == :completed end),
      do: :ok,
      else: {:error, :operation_in_flight}
  end

  defp step("DeploymentCreated", payload, nil) do
    with {:ok, release} <- ReleaseIdentity.new(Map.get(payload, "release", %{})),
         {:ok, environment} <- environment(payload["environment"]),
         true <- present?(payload["deployment_id"]) and present?(payload["project"]) do
      {:ok,
       %{
         deployment_id: payload["deployment_id"],
         project: payload["project"],
         environment: environment,
         release: release,
         release_id: payload["release_id"],
         requires_routing: payload["requires_routing"] == true,
         state: :queued,
         active: false,
         superseded_by: nil,
         health: %{status: :unknown, detail: nil, source: nil},
         cancellation_reason: nil,
         rollback_target: nil,
         operations: %{},
         last_operation_id: nil,
         last_identity: nil,
         event_count: 0
       }}
    else
      _ -> {:error, :malformed_creation}
    end
  end

  defp step("DeploymentCreated", _, _), do: {:error, :duplicate_creation}
  defp step(_, _, nil), do: {:error, :uncreated}

  defp step("DeploymentTransitioned", %{"state" => name}, projection) do
    with {:ok, to} <- Lifecycle.parse(name),
         {:ok, to} <- Lifecycle.transition(projection.state, to) do
      {:ok, %{projection | state: to}}
    end
  end

  defp step("DeploymentHealthObserved", %{"status" => status} = payload, projection)
       when status in @health do
    with :ok <- admitted(projection, :health) do
      {:ok,
       %{
         projection
         | health: %{
             status: String.to_existing_atom(status),
             detail: payload["detail"],
             source: payload["source"]
           }
       }}
    end
  end

  # The live-release pointer moves only through these two events.
  defp step("DeploymentActivated", _payload, projection) do
    with :ok <- admitted(projection, :activate),
         do: {:ok, %{projection | active: true, superseded_by: nil}}
  end

  defp step("DeploymentSuperseded", %{"by" => by}, %{active: true} = projection)
       when is_binary(by) and by != "",
       do: {:ok, %{projection | active: false, superseded_by: by}}

  defp step("DeploymentSuperseded", _payload, _projection), do: {:error, :not_active}

  defp step("DeploymentCancellationRequested", %{"reason" => reason}, projection)
       when is_binary(reason) and reason != "" and byte_size(reason) <= @max_reason do
    with :ok <- admitted(projection, :cancel),
         :ok <- no_open_operation(projection),
         :ok <- withdrawal_precedes_cancel(projection),
         do: {:ok, %{projection | cancellation_reason: reason}}
  end

  # From deploying, cancellation is only ever the tail of a withdrawal: the
  # facade writes the withdrawn completion and the cancellation together, so a
  # cancellation after an executor completion is a history it cannot produce.
  defp withdrawal_precedes_cancel(%{state: :deploying} = projection) do
    case projection.operations[projection.last_operation_id] do
      %{source: "withdrawn"} -> :ok
      _ -> {:error, :not_admitted}
    end
  end

  defp withdrawal_precedes_cancel(_projection), do: :ok

  # Host evidence recorded although the lifecycle could not move on it.
  defp step("DeploymentTransitionRefused", %{"from" => from, "to" => to}, projection) do
    with {:ok, from} <- Lifecycle.parse(from),
         {:ok, to} <- Lifecycle.parse(to),
         true <- from == projection.state,
         {:error, :invalid_transition} <- Lifecycle.transition(from, to) do
      {:ok, projection}
    else
      _ -> {:error, :unfounded_refusal}
    end
  end

  defp step(
         "DeploymentRollbackRequested",
         %{"target_deployment_id" => target} = payload,
         projection
       )
       when is_binary(target) and target != "" do
    with :ok <- admitted(projection, :rollback) do
      {:ok,
       %{
         projection
         | rollback_target: %{deployment_id: target, release_id: payload["target_release_id"]}
       }}
    end
  end

  defp step(
         "DeploymentOperationRequested",
         %{"operation_id" => id, "action" => action} = payload,
         projection
       )
       when is_binary(id) and id != "" do
    with {:ok, action} <- operation_action(action),
         false <- Map.has_key?(projection.operations, id),
         :ok <- admitted(projection, {:operation, action}),
         :ok <- no_open_operation(projection) do
      operation = %{
        action: action,
        phase: :requested,
        authorization_id: payload["authorization_id"],
        target_deployment_id: payload["target_deployment_id"],
        outcome: nil,
        source: nil,
        observations: []
      }

      {:ok, %{put_in(projection, [:operations, id], operation) | last_operation_id: id}}
    else
      true -> {:error, :duplicate_operation}
      error -> error
    end
  end

  defp step("DeploymentOperationStarted", %{"operation_id" => id}, projection),
    do: phase(projection, id, [:requested], &%{&1 | phase: :started})

  defp step(
         "DeploymentOperationCompleted",
         %{"operation_id" => id, "outcome" => outcome} = payload,
         projection
       )
       when outcome in ["succeeded", "failed"] do
    # A withdrawal closes an operation the executor never started; anything
    # else completes only what was started.
    from = if payload["source"] == "withdrawn", do: [:requested], else: [:started]

    phase(projection, id, from, fn operation ->
      %{
        operation
        | phase: :completed,
          outcome: String.to_existing_atom(outcome),
          source: payload["source"]
      }
    end)
  end

  defp step(
         "DeploymentOperationObserved",
         %{"operation_id" => id, "status" => status},
         projection
       )
       when is_binary(status) do
    phase(
      projection,
      id,
      [:started, :completed],
      &%{&1 | observations: &1.observations ++ [status]}
    )
  end

  defp step(_type, _payload, _projection), do: {:error, :unknown_event}

  defp phase(projection, id, allowed, update) do
    case Map.fetch(projection.operations, id) do
      {:ok, %{phase: phase} = operation} ->
        if phase in allowed,
          do: {:ok, put_in(projection, [:operations, id], update.(operation))},
          else: {:error, :operation_out_of_order}

      :error ->
        {:error, :unknown_operation}
    end
  end

  defp operation_action(name) when is_binary(name) do
    Enum.find_value(
      @operation_actions,
      {:error, :unknown_action},
      &if(Atom.to_string(&1) == name, do: {:ok, &1})
    )
  end

  defp operation_action(_), do: {:error, :unknown_action}

  defp environment(name) when is_binary(name) do
    Enum.find_value(
      Lifecycle.environments(),
      {:error, :unknown_environment},
      &if(Atom.to_string(&1) == name, do: {:ok, &1})
    )
  end

  defp environment(_), do: {:error, :unknown_environment}

  defp present?(value), do: is_binary(value) and value != ""
end
