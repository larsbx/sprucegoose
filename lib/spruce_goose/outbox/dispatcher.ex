defmodule SpruceGoose.Outbox.Dispatcher do
  @moduledoc false
  use Oban.Worker,
    queue: :outbox,
    max_attempts: 20,
    unique: [period: 60, fields: [:worker, :queue]]

  import Ecto.Query

  alias SpruceGoose.Outbox.Event
  alias SpruceGoose.Repo

  @max_event_attempts 20
  @base_backoff_seconds 5
  @max_backoff_seconds 3_600

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(_opts) do
    Task.start_link(fn -> enqueue() end)
  end

  def enqueue do
    %{}
    |> new(schedule_in: 1)
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(_job) do
    dispatch_batch(configured_handler())
    enqueue()
    :ok
  end

  def dispatch_batch(handler) when is_function(handler, 1) do
    Repo.transaction(fn ->
      events =
        Event
        |> where([event], event.status == :pending and event.available_at <= ^DateTime.utc_now())
        |> order_by([event], asc: event.inserted_at)
        |> limit(100)
        |> lock("FOR UPDATE SKIP LOCKED")
        |> Repo.all()

      Enum.map(events, &dispatch(&1, handler))
    end)
  end

  def dispatch_batch(handler) when is_atom(handler), do: dispatch_batch(&handler.deliver/1)

  defp dispatch(event, handler) do
    case handler.(event) do
      :ok ->
        now = DateTime.utc_now()

        from(item in Event, where: item.id == ^event.id)
        |> Repo.update_all(
          set: [status: :dispatched, dispatched_at: now, last_error: nil, updated_at: now],
          inc: [attempts: 1]
        )

        {:ok, event.id}

      {:error, reason} ->
        now = DateTime.utc_now()
        attempts = event.attempts + 1
        status = if attempts >= @max_event_attempts, do: :failed, else: :pending
        available_at = DateTime.add(now, backoff_seconds(attempts), :second)

        from(item in Event, where: item.id == ^event.id)
        |> Repo.update_all(
          set: [
            status: status,
            available_at: available_at,
            last_error: reason |> inspect() |> String.slice(0, 4_000),
            updated_at: now
          ],
          inc: [attempts: 1]
        )

        {:error, event.id}
    end
  end

  defp configured_handler do
    case Application.get_env(:spruce_goose, :outbox_handler) do
      handler when is_atom(handler) and not is_nil(handler) -> handler
      _ -> raise "outbox delivery requires a configured :outbox_handler"
    end
  end

  defp backoff_seconds(attempts) do
    min(@base_backoff_seconds * Integer.pow(2, max(attempts - 1, 0)), @max_backoff_seconds)
  end
end
