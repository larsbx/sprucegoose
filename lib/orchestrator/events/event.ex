defmodule Orchestrator.Events.Event do
  use Ash.Resource,
    domain: Orchestrator.Notes,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog]

  event_log do
    clear_records_for_replay(Orchestrator.Events.ClearAllRecords)
    primary_key_type(:integer)
    record_id_type(:uuid)
  end

  postgres do
    table "events"
    repo Orchestrator.Repo
  end

  actions do
    defaults [:read]
  end

  # Q2 probe: can the (auto-generated) create action reject events before
  # persistence? Simulates envelope verification-on-append.
  validations do
    validate fn changeset, _ctx ->
      metadata = Ash.Changeset.get_attribute(changeset, :metadata) || %{}

      if Map.get(metadata, "reject_me") do
        {:error, field: :metadata, message: "verification failed (spike probe)"}
      else
        :ok
      end
    end
  end
end
