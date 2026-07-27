defmodule Orchestrator.Workflows.TaskDefinition do
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute(:id, :string, allow_nil?: false, public?: true)
    attribute(:kind, Orchestrator.Workflows.TaskKind, allow_nil?: false, public?: true)

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
  end
end
