defmodule SpruceGoose.Events.Event do
  use Ash.Resource,
    domain: SpruceGoose.Notes,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog]

  postgres do
    table "events"
    repo SpruceGoose.Repo
  end

  event_log do
    clear_records_for_replay(SpruceGoose.Events.ClearAllRecords)
    primary_key_type(:integer)
    record_id_type(:uuid)
  end

  actions do
    defaults [:read]
  end
end
