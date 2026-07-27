defmodule Orchestrator.Notes.Note do
  use Ash.Resource,
    domain: Orchestrator.Notes,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  events do
    event_log(Orchestrator.Events.Event)
  end

  postgres do
    table "notes"
    repo Orchestrator.Repo
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :body, :string, allow_nil?: false, public?: true
    attribute :counter, :integer, default: 0, public?: true
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:id, :body, :counter]
    end

    update :update do
      primary? true
      accept [:body, :counter]
      require_atomic? false
    end

    destroy :destroy do
      primary? true
      require_atomic? false
    end
  end
end
