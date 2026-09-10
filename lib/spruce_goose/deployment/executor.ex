defmodule SpruceGoose.Deployment.Executor do
  @moduledoc """
  Drives one requested operation through the configured host adapter.

  The phase is committed *before* the effect begins: a crash mid-effect leaves
  the operation `started`, and the retry reconciles what the host observed
  rather than performing the effect again. A timeout is handled the same way.
  Only an outcome the host confirms — by the adapter's own receipt or by
  inspection — is recorded as completed, and the source is recorded with it.
  """

  use Oban.Worker,
    queue: :deployments,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :args]]

  alias SpruceGoose.{Authz, Deployment}
  alias SpruceGoose.Actors.Actor
  alias SpruceGoose.Deployment.Operation

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"operation_id" => operation_id}} = job)
      when map_size(job.args) == 1 and is_binary(operation_id) do
    with {:ok, actor} <- executor_actor(),
         {:ok, adapter} <- adapter() do
      Authz.with_actor(actor, fn -> execute(operation_id, actor.name, adapter) end)
    else
      {:error, reason} -> {:discard, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, "expected exactly one operation_id"}

  @doc "Run one operation as the given executor through an adapter. Exposed for direct invocation."
  def execute(operation_id, executor_id, adapter) do
    with {:ok, operation} <- Authz.read_one(Operation, operation_id: operation_id) do
      case operation.phase do
        :completed ->
          {:discard, "operation already completed"}

        :requested ->
          with(
            {:ok, operation} <- Deployment.start_operation(operation_id, executor_id),
            do: run(operation, adapter)
          )

        :started ->
          reconcile(operation, adapter)
      end
    end
    |> normalize()
  end

  defp run(operation, adapter) do
    with {:ok, request} <- Deployment.operation_request(operation) do
      task = Task.async(fn -> adapter.execute(request) end)

      case Task.yield(task, timeout()) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, receipt}} when is_map(receipt) ->
          complete(operation, :succeeded, receipt, "executor")

        {:ok, {:error, reason}} ->
          complete(operation, :failed, %{detail: message(reason)}, "executor")

        {:ok, other} ->
          complete(
            operation,
            :failed,
            %{detail: "adapter returned malformed receipt: #{inspect(other)}"},
            "executor"
          )

        # The effect may or may not have happened. Ask the host before deciding.
        _timeout_or_exit ->
          reconcile(operation, adapter)
      end
    end
  end

  defp reconcile(operation, adapter) do
    with {:ok, request} <- Deployment.operation_request(operation),
         {:ok, %{status: status} = observation} <- observe(adapter, request),
         {:ok, _} <-
           Deployment.observe_operation(operation.operation_id, status, observation[:detail]) do
      case status do
        :succeeded ->
          complete(operation, :succeeded, observation, "observation")

        :failed ->
          complete(operation, :failed, observation, "observation")

        _ ->
          {:error,
           "operation #{operation.operation_id} is #{status} on the host; will reconcile again"}
      end
    end
  end

  defp observe(adapter, request) do
    case adapter.observe(request) do
      {:ok, %{status: status} = observation}
      when status in [:succeeded, :failed, :in_progress, :unknown] ->
        {:ok, observation}

      {:ok, other} ->
        {:error, "adapter returned malformed observation: #{inspect(other)}"}

      {:error, reason} ->
        {:error, "host inspection failed: " <> message(reason)}
    end
  end

  defp complete(operation, outcome, attrs, source) do
    Deployment.complete_operation(operation.operation_id, outcome, %{
      evidence_digest: attrs[:evidence_digest],
      detail: attrs[:detail],
      source: source
    })
  end

  defp normalize({:ok, _}), do: :ok
  defp normalize({:discard, _} = discard), do: discard
  defp normalize({:error, reason}), do: {:error, message(reason)}

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason) when is_exception(reason), do: Exception.message(reason)
  defp message(reason), do: inspect(reason)

  defp timeout, do: Application.get_env(:spruce_goose, :deployment_operation_timeout_ms, 600_000)

  defp adapter do
    case Application.get_env(:spruce_goose, :deployment_host_adapter) do
      module when is_atom(module) and not is_nil(module) ->
        if Code.ensure_loaded?(module) and function_exported?(module, :execute, 1) and
             function_exported?(module, :observe, 1),
           do: {:ok, module},
           else:
             {:error, "deployment host adapter #{inspect(module)} does not implement HostAdapter"}

      _ ->
        {:error, "deployment host adapter is not configured"}
    end
  end

  defp executor_actor do
    with name when is_binary(name) <-
           Application.get_env(:spruce_goose, :deployment_executor_actor),
         {:ok, %Actor{} = actor} <- SpruceGoose.Actors.Resolver.resolve(name),
         true <- Actor.active?(actor) do
      {:ok, actor}
    else
      nil -> {:error, "deployment executor actor is not configured"}
      false -> {:error, "deployment executor actor is disabled"}
      {:error, reason} -> {:error, message(reason)}
    end
  end
end
