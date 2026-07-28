defmodule SpruceGoose.Outbox.Event do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "outbox_events" do
    field(:event_key, :string)
    field(:aggregate_type, :string)
    field(:aggregate_id, :string)
    field(:event_type, :string)
    field(:payload, :map)
    field(:status, Ecto.Enum, values: [:pending, :dispatched, :failed])
    field(:attempts, :integer)
    field(:available_at, :utc_datetime_usec)
    field(:dispatched_at, :utc_datetime_usec)
    field(:last_error, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
