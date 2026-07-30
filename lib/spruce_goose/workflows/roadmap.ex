defmodule SpruceGoose.Workflows.Roadmap do
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("roadmaps")
    repo(SpruceGoose.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:key, :string, allow_nil?: false, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :project, SpruceGoose.Workflows.Project do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    has_many(:workflows, SpruceGoose.Workflows.Workflow)
  end

  actions do
    defaults([:read])

    update :rename do
      accept([:name])
    end

    destroy :destroy do
      primary?(true)
    end

    create :create do
      primary?(true)
      accept([:project_id, :key, :name])
    end
  end

  identities do
    identity(:unique_roadmap_key_per_project, [:project_id, :key])
  end
end
