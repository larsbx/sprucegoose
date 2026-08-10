defmodule SpruceGoose.Outbox.Operator do
  @moduledoc false

  import Ecto.Query

  alias SpruceGoose.Actors.Scope
  alias SpruceGoose.Authz
  alias SpruceGoose.Outbox.Event
  alias SpruceGoose.Repo

  def list_failed do
    with :ok <- authorize_admin() do
      events =
        Event
        |> where([event], event.status == :failed)
        |> order_by([event], asc: event.inserted_at)
        |> Repo.all()

      {:ok, %{events: Enum.map(events, &event_json/1)}}
    end
  end

  def replay(event_id) do
    with :ok <- authorize_admin() do
      Repo.transaction(fn ->
        event =
          Event
          |> where([event], event.id == ^event_id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        case event do
          nil ->
            Repo.rollback("outbox event not found")

          %Event{status: :failed} ->
            now = DateTime.utc_now()

            from(item in Event, where: item.id == ^event_id and item.status == :failed)
            |> Repo.update_all(
              set: [
                status: :pending,
                attempts: 0,
                available_at: now,
                dispatched_at: nil,
                last_error: nil,
                updated_at: now
              ]
            )

            event
            |> Map.merge(%{
              status: :pending,
              attempts: 0,
              available_at: now,
              dispatched_at: nil,
              last_error: nil
            })
            |> event_json()

          %Event{} ->
            Repo.rollback("only failed outbox events may be replayed")
        end
      end)
    end
  end

  defp authorize_admin do
    actor = Authz.actor!()

    if Scope.holds?(actor, :admin, :global) do
      :ok
    else
      {:error, "outbox failed-event inspection and replay require admin at global scope"}
    end
  end

  defp event_json(event) do
    %{
      id: event.id,
      event_key: event.event_key,
      aggregate_type: event.aggregate_type,
      aggregate_id: event.aggregate_id,
      event_type: event.event_type,
      status: event.status,
      attempts: event.attempts,
      available_at: event.available_at,
      dispatched_at: event.dispatched_at,
      last_error: event.last_error
    }
  end
end
