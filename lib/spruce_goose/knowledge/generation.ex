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

    # Born active, retired once. The caller does not choose the initial state.
    attribute(:state, :atom,
      allow_nil?: false,
      default: :active,
      constraints: [one_of: [:active, :retired]],
      public?: true
    )

    timestamps()
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:source, :source_revision, :source_digest])
    end

    update :retire do
      accept([])
      validate(attribute_equals(:state, :active), message: "generation is already retired")
      change(set_attribute(:state, :retired))
    end
  end

  identities do
    identity(:unique_source_digest, [:source_digest])
  end
end
