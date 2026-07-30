defmodule SpruceGoose.Knowledge.Generation do
  use Ash.Resource,
    domain: SpruceGoose.Knowledge.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("knowledge_generations")
    repo(SpruceGoose.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:source, :string, allow_nil?: false, public?: true)
    attribute(:source_revision, :string, allow_nil?: false, public?: true)
    attribute(:source_digest, :string, allow_nil?: false, public?: true)

    attribute(:state, :atom,
      allow_nil?: false,
      constraints: [one_of: [:active, :retired]],
      public?: true
    )

    timestamps()
  end

  identities do
    identity(:unique_source_digest, [:source_digest])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:source, :source_revision, :source_digest, :state])
    end

    update :retire do
      accept([])
      change(set_attribute(:state, :retired))
    end
  end
end
