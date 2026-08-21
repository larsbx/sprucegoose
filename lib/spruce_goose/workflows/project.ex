defmodule SpruceGoose.Workflows.Project do
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}

  postgres do
    table("projects")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(Readable)
    end

    # A project cannot be scoped to itself before it exists, so creating one
    # resolves to global scope and needs a fleet-wide author grant.
    policy action_type([:create, :destroy]) do
      authorize_if(HasRole.author())
    end

    policy action(:rename) do
      authorize_if(HasRole.author())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:key, :string, allow_nil?: false, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    timestamps()
  end

  relationships do
    has_many(:roadmaps, SpruceGoose.Workflows.Roadmap)
    has_many(:blueprint_revisions, SpruceGoose.Workflows.BlueprintRevision)
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
      accept([:key, :name])
    end
  end

  identities do
    identity(:unique_project_key, [:key])
  end
end
