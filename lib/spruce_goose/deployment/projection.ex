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
         health: %{status: :unknown, detail: nil},
         cancellation_reason: nil,
         rollback_target: nil,
         operations: %{},
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
    {:ok,
     %{projection | health: %{status: String.to_existing_atom(status), detail: payload["detail"]}}}
  end

  defp step("DeploymentCancellationRequested", %{"reason" => reason}, projection)
       when is_binary(reason) and reason != "" and byte_size(reason) <= @max_reason do
    {:ok, %{projection | cancellation_reason: reason}}
  end

  defp step(
         "DeploymentRollbackRequested",
         %{"target_deployment_id" => target} = payload,
         projection
       )
       when is_binary(target) and target != "" do
    {:ok,
     %{
       projection
       | rollback_target: %{deployment_id: target, release_id: payload["target_release_id"]}
     }}
  end

  defp step(
         "DeploymentOperationRequested",
         %{"operation_id" => id, "action" => action} = payload,
         projection
       )
       when is_binary(id) and id != "" do
    with {:ok, action} <- operation_action(action),
         false <- Map.has_key?(projection.operations, id) do
      operation = %{
        action: action,
        phase: :requested,
        authorization_id: payload["authorization_id"],
        target_deployment_id: payload["target_deployment_id"],
        outcome: nil,
        source: nil,
        observations: []
      }

      {:ok, put_in(projection, [:operations, id], operation)}
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
    phase(projection, id, [:started], fn operation ->
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
