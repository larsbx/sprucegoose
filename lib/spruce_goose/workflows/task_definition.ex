defmodule SpruceGoose.Workflows.TaskDefinition do
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute(:id, :string, allow_nil?: false, public?: true)
    attribute(:kind, SpruceGoose.Workflows.TaskKind, allow_nil?: false, public?: true)
    attribute(:title, :string, public?: true)
    attribute(:definition_of_done, :string, public?: true)

    attribute(:depends_on, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true
    )

    attribute(:input, :map, allow_nil?: false, default: %{}, public?: true)
  end

  actions do
    default_accept(:*)
    defaults([:read, create: :*])
  end

  validations do
    validate(string_length(:id, min: 1, max: 128))
    validate(string_length(:title, min: 1, max: 300))
    validate(string_length(:definition_of_done, min: 1, max: 2_000))
  end
end
