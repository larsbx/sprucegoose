defmodule SpruceGoose.Outbox.Dispatcher do
  @moduledoc false
  use Oban.Worker,
    queue: :outbox,
    max_attempts: 20

  import Ecto.Query

  alias SpruceGoose.Outbox.Event
  alias SpruceGoose.Repo

  @max_event_attempts 20
  @base_backoff_seconds 5
  @max_backoff_seconds 3_600
  @minimum_claim_lease_seconds 60
  @default_delivery_timeout 30_000

  def cron_config, do: [{"* * * * *", __MODULE__}]

  def validate_handler(handler) when is_atom(handler) do
    if Code.ensure_loaded?(handler) and function_exported?(handler, :deliver, 1) do
      :ok
    else
      {:error, "OUTBOX_HANDLER must name a loaded module that exports deliver/1"}
    end
  end

  def validate_handler(_handler),
    do: {:error, "OUTBOX_HANDLER must name a loaded module that exports deliver/1"}

  @impl Oban.Worker
  def perform(_job) do
    dispatch_batch(configured_handler())
    :ok
  end

  def dispatch_batch(handler, opts \\ [])

  def dispatch_batch(handler, opts) when is_function(handler, 1) do
    dispatch_available(handler, opts, 100, [])
  end

  def dispatch_batch(handler, opts) when is_atom(handler),
    do: dispatch_batch(&handler.deliver/1, opts)

  defp dispatch_available(_handler, _opts, 0, results), do: {:ok, Enum.reverse(results)}

  defp dispatch_available(handler, opts, remaining, results) do
    case claim_one() do
      {:ok, nil} ->
        {:ok, Enum.reverse(results)}

      {:ok, event} ->
        result = dispatch(event, handler, opts)
        dispatch_available(handler, opts, remaining - 1, [result | results])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch(event, handler, opts) do
    result = deliver(handler, event)
    after_delivery = Keyword.get(opts, :after_delivery, fn _event, _result -> :ok end)
    after_delivery.(event, result)

    case result do
      :ok ->
        now = DateTime.utc_now()

        updated =
          from(item in Event,
            where:
              item.id == ^event.id and item.status == :pending and
                item.available_at == ^event.available_at
          )
          |> Repo.update_all(
            set: [status: :dispatched, dispatched_at: now, last_error: nil, updated_at: now],
            inc: [attempts: 1]
          )

        outcome(updated, :ok, event.id)

      {:error, reason} ->
        now = DateTime.utc_now()
        attempts = event.attempts + 1
        status = if attempts >= @max_event_attempts, do: :failed, else: :pending
        available_at = DateTime.add(now, backoff_seconds(attempts), :second)

        updated =
          from(item in Event,
            where:
              item.id == ^event.id and item.status == :pending and
                item.available_at == ^event.available_at
          )
          |> Repo.update_all(
            set: [
              status: status,
              available_at: available_at,
              last_error: reason |> inspect() |> String.slice(0, 4_000),
              updated_at: now
            ],
            inc: [attempts: 1]
          )

        outcome(updated, :error, event.id)
    end
  end

  defp claim_one do
    Repo.transaction(fn ->
      now = DateTime.utc_now()
      lease_until = DateTime.add(now, claim_lease_seconds(), :second)

      event =
        Event
        |> where([event], event.status == :pending and event.available_at <= ^now)
        |> order_by([event], asc: event.inserted_at)
        |> limit(1)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.one()

      if event do
        from(item in Event, where: item.id == ^event.id)
        |> Repo.update_all(set: [available_at: lease_until, updated_at: now])

        %{event | available_at: lease_until, updated_at: now}
      else
        nil
      end
    end)
  end

  defp outcome({1, _}, kind, event_id), do: {kind, event_id}
  defp outcome({0, _}, _kind, event_id), do: {:stale, event_id}

  defp deliver(handler, event) do
    caller = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            case handler.(event) do
              :ok -> :ok
              {:error, reason} -> {:error, reason}
              other -> {:error, {:malformed_result, other}}
            end
          rescue
            exception -> {:error, {:raise, Exception.message(exception)}}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(caller, {token, result})
      end)

    receive do
      {^token, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:exit, reason}}
    after
      delivery_timeout() ->
        Process.exit(pid, :kill)
        receive do: ({:DOWN, ^monitor, :process, ^pid, _reason} -> :ok)
        {:error, :timeout}
    end
  end

  defp configured_handler do
    case Application.get_env(:spruce_goose, :outbox_handler) do
      handler when is_function(handler, 1) -> handler
      handler when is_atom(handler) and not is_nil(handler) -> handler
      _ -> raise "outbox delivery requires a configured :outbox_handler"
    end
  end

  defp delivery_timeout do
    Application.get_env(:spruce_goose, :outbox_delivery_timeout_ms, @default_delivery_timeout)
  end

  defp claim_lease_seconds do
    max(@minimum_claim_lease_seconds, div(delivery_timeout() + 999, 1_000) + 30)
  end

  defp backoff_seconds(attempts) do
    min(@base_backoff_seconds * Integer.pow(2, max(attempts - 1, 0)), @max_backoff_seconds)
  end
end
