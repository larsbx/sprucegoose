defmodule SpruceGoose.Events.ClearAllRecords do
  use AshEvents.ClearRecordsForReplay

  import Ecto.Query

  @impl true
  def clear_records!(_opts) do
    SpruceGoose.Repo.delete_all(from(n in "notes"))
    :ok
  end
end
