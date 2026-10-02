defmodule SpruceGoose.AgentHooks.Delivery do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:run_id, Ecto.UUID, autogenerate: false}

  schema "agent_hook_deliveries" do
    field(:claim_id, Ecto.UUID)
    field(:claimed_until, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    field(:attempts, :integer, default: 0)
    timestamps(type: :utc_datetime_usec)
  end
end
