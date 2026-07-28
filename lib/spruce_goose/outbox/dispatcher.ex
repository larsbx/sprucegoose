defmodule SpruceGoose.Outbox.Dispatcher do
  @moduledoc false
  use Oban.Worker,
    queue: :outbox,
    max_attempts: 20,
    unique: [period: 60, fields: [:worker, :queue]]

  import Ecto.Query

  alias SpruceGoose.Outbox.Event
  alias SpruceGoose.Repo

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
    dispatch_batch()
    enqueue()
    :ok
  end

  def dispatch_batch(handler \\ &default_handler/1) do
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

        from(item in Event, where: item.id == ^event.id)
        |> Repo.update_all(
          set: [last_error: inspect(reason), updated_at: now],
          inc: [attempts: 1]
        )

        {:error, event.id}
    end
  end

  defp default_handler(_event), do: :ok
end
