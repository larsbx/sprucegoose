defmodule Orchestrator.Workflows.Roadmap do
  use Ash.Resource,
    domain: Orchestrator.Workflows,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("roadmaps")
    repo(Orchestrator.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:key, :string, allow_nil?: false, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :project, Orchestrator.Workflows.Project do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    has_many(:workflows, Orchestrator.Workflows.Workflow)
  end

  identities do
    identity(:unique_roadmap_key_per_project, [:project_id, :key])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:project_id, :key, :name])
    end
  end
end
