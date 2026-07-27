defmodule SpruceGoose.Workflows.Project do
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("projects")
    repo(SpruceGoose.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:key, :string, allow_nil?: false, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    timestamps()
  end

  relationships do
    has_many(:roadmaps, SpruceGoose.Workflows.Roadmap)
  end

  identities do
    identity(:unique_project_key, [:key])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:key, :name])
    end
  end
end
