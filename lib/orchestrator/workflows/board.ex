defmodule Orchestrator.Workflows.Board do
  use Ash.Resource,
    domain: Orchestrator.Workflows,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("boards")
    repo(Orchestrator.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:key, :string, allow_nil?: false, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:lock_version, :integer, allow_nil?: false, default: 1, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :workflow, Orchestrator.Workflows.Workflow do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    has_many(:columns, Orchestrator.Workflows.BoardColumn)
    has_many(:tasks, Orchestrator.Workflows.Task)
    has_many(:saved_filters, Orchestrator.Workflows.SavedFilter)
  end

  identities do
    identity(:unique_board_key_per_workflow, [:workflow_id, :key])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:workflow_id, :key, :name])
    end

    update :revise do
      accept([:name])
      change(optimistic_lock(:lock_version))
    end
  end
end
