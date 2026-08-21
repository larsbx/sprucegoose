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

    attribute(:artifact_requirements, {:array, :string},
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

    validate(fn changeset, _context ->
      requirements = Ash.Changeset.get_attribute(changeset, :artifact_requirements) || []

      valid? =
        length(requirements) <= 50 and
          Enum.uniq(requirements) == requirements and
          Enum.all?(requirements, fn value ->
            is_binary(value) and String.trim(value) == value and value != "" and
              byte_size(value) <= 128
          end)

      if valid?,
        do: :ok,
        else: {:error, field: :artifact_requirements, message: "must be unique bounded names"}
    end)
  end
end
