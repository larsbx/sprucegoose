defmodule SpruceGoose.Knowledge.Node do
  use Ash.Resource,
    domain: SpruceGoose.Knowledge.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("knowledge_nodes")
    repo(SpruceGoose.Repo)
  end

  attributes do
    uuid_primary_key(:row_id)
    attribute(:generation_id, :uuid, allow_nil?: false, public?: true)
    attribute(:id, :string, allow_nil?: false, public?: true)
    attribute(:label, :string, allow_nil?: false, public?: true)
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

  identities do
    identity(:unique_node_per_generation, [:generation_id, :id])
    identity(:unique_node_position, [:generation_id, :position])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:generation_id, :id, :label, :source_file, :source_location, :origin, :position])
    end
  end
end
