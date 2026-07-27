defmodule Orchestrator.Events.ClearAllRecords do
  use AshEvents.ClearRecordsForReplay

  import Ecto.Query

  @impl true
  def clear_records!(_opts) do
    Orchestrator.Repo.delete_all(from(n in "notes"))
    :ok
  end
end
