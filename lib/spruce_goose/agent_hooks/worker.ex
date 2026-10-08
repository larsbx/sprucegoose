defmodule SpruceGoose.AgentHooks.Worker do
  @moduledoc "Bounded agent computation outside transactions, followed by a guarded proposal commit."
  use Oban.Worker,
    queue: :agent_hooks,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker, :args], states: :all]

  alias SpruceGoose.AgentHooks.Store

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => id} = args})
      when map_size(args) == 1 and is_binary(id) do
    case Store.claim(id) do
      {:ok, {:claimed, run, token, config, _actor}} ->
        result = invoke(config.handler, run.context, config.descriptor["timeout_ms"])

        case Store.finish(id, token, result) do
          {:ok, _} ->
            :ok

          {:error, reason} when reason in [:stale_claim, :expired_claim] ->
            {:discard, "stale triage claim"}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, {:terminal, _}} ->
        :ok

      {:ok, {:busy, seconds}} ->
        {:snooze, seconds + 1}

      {:error, :unknown_run} ->
        {:discard, "unknown agent run"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, "expected exactly one run_id"}

  defp invoke(handler, context, timeout) do
    parent = self()
    token = make_ref()

    # The guard monitors the worker and is linked to the adapter process.
    # Worker death or timeout kills the in-flight computation as well.
    {guard, monitor} =
      spawn_monitor(fn ->
        worker_monitor = Process.monitor(parent)
        guard = self()

        adapter =
          spawn_link(fn ->
            result =
              try do
                handler.propose(context)
              rescue
                _ -> {:error, :handler_raised}
              catch
                _, _ -> {:error, :handler_exited}
              end

            send(guard, {token, result})
          end)

        receive do
          {^token, result} -> send(parent, {token, result})
          {:DOWN, ^worker_monitor, :process, ^parent, _} -> Process.exit(adapter, :kill)
        after
          timeout ->
            send(parent, {token, {:error, :handler_timeout}})
            Process.exit(adapter, :kill)
        end
      end)

    receive do
      {^token, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^guard, _} ->
        {:error, :handler_process_failed}
    after
      timeout + 1_000 ->
        Process.exit(guard, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :handler_timeout}
    end
  end
end
