defmodule SpruceGoose.Derivations.Executor do
  @moduledoc """
  Executes one typed derivation permit through an allowlisted handler.

  Jobs carry only a permit ID. Source identity, action, authorization, and
  lifecycle remain in SpruceGoose; repository workflow commands are never job
  input.
  """

  use Oban.Worker,
    queue: :derivations,
    max_attempts: 1,
    unique: [period: :infinity, fields: [:worker, :args]]

  require Ash.Query

  alias SpruceGoose.Actors.Actor
  alias SpruceGoose.Authz
  alias SpruceGoose.Derivations.Permit
  alias SpruceGoose.Kernel.ShadowEvents

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"permit_id" => permit_id}} = job)
      when map_size(job.args) == 1 and is_binary(permit_id) do
    with {:ok, actor} <- executor_actor() do
      Authz.with_actor(actor, fn -> execute(permit_id, actor.name) end)
    else
      {:error, reason} -> {:discard, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, "expected exactly one permit_id"}

  defp execute(permit_id, executor_id) do
    with {:ok, permit} <- Authz.read_one(Permit, permit_id: permit_id),
         {:ok, claimed} <- shadow_update(permit, %{executor_id: executor_id}, :claim) do
      run_handler(claimed)
    else
      {:error, reason} -> {:discard, message(reason)}
    end
  end

  defp run_handler(permit) do
    case handler_for(permit.action) do
      {:ok, handler} ->
        invoke_handler(handler, permit)

      {:error, reason} ->
        fail(permit, reason)
    end
  end

  defp invoke_handler(handler, permit) do
    result =
      try do
        handler.run(permit)
      rescue
        exception -> {:error, Exception.message(exception)}
      catch
        kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
      end

    case result do
      {:ok, %{evidence_digest: evidence} = outcome} ->
        input = %{
          evidence_digest: evidence,
          artifact_digest: Map.get(outcome, :artifact_digest)
        }

        case shadow_update(permit, input, :succeed) do
          {:ok, _completed} -> :ok
          {:error, reason} -> {:discard, message(reason)}
        end

      {:error, reason} ->
        fail(permit, message(reason))

      other ->
        fail(permit, "handler returned malformed outcome: #{inspect(other)}")
    end
  end

  defp fail(permit, reason) do
    case shadow_update(permit, %{failure_reason: reason}, :fail) do
      {:ok, _failed} -> {:discard, reason}
      {:error, error} -> {:discard, message(error)}
    end
  end

  defp shadow_update(permit, input, action) do
    ShadowEvents.transaction({:derivation_transition, permit.permit_id, action}, fn ->
      Authz.update(permit, input, action: action)
    end)
  end

  defp handler_for(action) do
    handlers = Application.get_env(:spruce_goose, :derivation_handlers, %{})

    case Map.get(handlers, action) do
      nil ->
        {:error, "no handler configured for #{action}"}

      handler when is_atom(handler) ->
        if Code.ensure_loaded?(handler) and function_exported?(handler, :run, 1),
          do: {:ok, handler},
          else: {:error, "invalid handler configured for #{action}"}

      _other ->
        {:error, "invalid handler configured for #{action}"}
    end
  end

  defp executor_actor do
    name = Application.get_env(:spruce_goose, :derivation_executor_actor)

    if is_binary(name) and name != "" do
      result =
        Actor
        |> Ash.Query.filter_input(name: name)
        |> Ash.read_one(authorize?: false)

      case result do
        {:ok, %Actor{} = actor} ->
          if Actor.active?(actor),
            do: {:ok, actor},
            else: {:error, "derivation executor is disabled"}

        _ ->
          {:error, "derivation executor actor is not configured"}
      end
    else
      {:error, "derivation executor actor is not configured"}
    end
  end

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason) when is_exception(reason), do: Exception.message(reason)
  defp message(reason), do: inspect(reason)
end
