defmodule SpruceGoose.Events.ClearAllRecords do
  @moduledoc """
  Clear the projected records an AshEvents replay is about to rebuild.

  This deletes every note unconditionally, which is correct for a replay and
  catastrophic for anything else. Nothing calls it today, and there is no
  supported operator path that would — so it refuses unless a replay has
  explicitly been enabled for this node, rather than sitting available as a
  destructive capability with no gate at all.
  """

  use AshEvents.ClearRecordsForReplay

  import Ecto.Query

  @impl true
  def clear_records!(_opts) do
    unless Application.get_env(:spruce_goose, :allow_event_replay, false) do
      raise "AshEvents replay would delete every note. Set :allow_event_replay " <>
              "for this node first; it is not an operator workflow"
    end

    SpruceGoose.Repo.delete_all(from(n in "notes"))
    :ok
  end
end
