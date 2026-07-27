defmodule SpruceGoose.Workflows.Workflow do
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer

  alias SpruceGoose.Workflows.Definition

  postgres do
    table("workflows")
    repo(SpruceGoose.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:workflow_id, :string, allow_nil?: false, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:definition, Definition, allow_nil?: false, public?: true)
    attribute(:lock_version, :integer, allow_nil?: false, default: 1, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :roadmap, SpruceGoose.Workflows.Roadmap do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    has_many(:tasks, SpruceGoose.Workflows.Task)
  end

  identities do
    identity(:unique_workflow_id_per_roadmap, [:roadmap_id, :workflow_id])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:roadmap_id, :workflow_id, :name, :definition])
    end

    update :replace_definition do
      accept([:definition])
      change(optimistic_lock(:lock_version))
    end
  end
end
