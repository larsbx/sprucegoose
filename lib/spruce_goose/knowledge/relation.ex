defmodule SpruceGoose.Knowledge.Relation do
  use Ash.Resource,
    domain: SpruceGoose.Knowledge.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("knowledge_relations")
    repo(SpruceGoose.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:generation_id, :uuid, allow_nil?: false, public?: true)
    attribute(:source, :string, allow_nil?: false, public?: true)
    attribute(:target, :string, allow_nil?: false, public?: true)
    attribute(:relation, :string, allow_nil?: false, public?: true)
    attribute(:confidence, :string, allow_nil?: false, public?: true)
    attribute(:source_file, :string, allow_nil?: false, public?: true)
    attribute(:source_location, :string, allow_nil?: false, public?: true)
    attribute(:origin, :string, allow_nil?: false, public?: true)
    attribute(:position, :integer, allow_nil?: false, public?: true)
    timestamps()
  end

  relationships do
    belongs_to(:generation, SpruceGoose.Knowledge.Generation,
      source_attribute: :generation_id,
      destination_attribute: :id,
      define_attribute?: false
    )
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)

      accept([
        :generation_id,
        :source,
        :target,
        :relation,
        :confidence,
        :source_file,
        :source_location,
        :origin,
        :position
      ])
    end
  end

  identities do
    identity(:unique_relation_position, [:generation_id, :position])
  end
end
