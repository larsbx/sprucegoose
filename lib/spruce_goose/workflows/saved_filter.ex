defmodule SpruceGoose.Workflows.SavedFilter do
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}

  @allowed_keys MapSet.new(["assignee", "column", "label", "priority", "state", "text"])
  @states ~w(inbox proposed queued ready in_progress waiting blocked completed failed cancelled)

  postgres do
    table("saved_filters")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(Readable)
    end

    policy action_type([:create, :destroy]) do
      authorize_if(HasRole.author())
    end

    policy action(:revise) do
      authorize_if(HasRole.approver())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:criteria, :map, allow_nil?: false, default: %{}, public?: true)
    attribute(:lock_version, :integer, allow_nil?: false, default: 1, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :board, SpruceGoose.Workflows.Board do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    update :revise do
      require_atomic?(false)
      accept([:name, :criteria])
      change(optimistic_lock(:lock_version))
    end

    destroy :destroy do
      primary?(true)
    end

    create :create do
      primary?(true)
      accept([:board_id, :name, :criteria])
    end
  end

  identities do
    identity(:unique_filter_name_per_board, [:board_id, :name])
  end

  validations do
    validate(fn changeset, _context ->
      criteria = Ash.Changeset.get_attribute(changeset, :criteria) || %{}
      unknown = Map.keys(criteria) |> MapSet.new() |> MapSet.difference(@allowed_keys)

      if MapSet.size(unknown) == 0,
        do: valid_criteria(criteria),
        else: {:error, field: :criteria, message: "contains unsupported filter keys"}
    end)
  end

  defp valid_criteria(criteria) do
    valid =
      Enum.all?(criteria, fn
        {"assignee", value} ->
          bounded_text?(value)

        {"column", value} ->
          bounded_text?(value)

        {"label", value} ->
          bounded_text?(value)

        {"text", value} ->
          bounded_text?(value)

        {"priority", value} ->
          is_integer(value) and value in 0..5

        {"state", value} when is_binary(value) ->
          value in @states

        {"state", values} when is_list(values) ->
          values != [] and Enum.all?(values, &(&1 in @states))
      end)

    if valid,
      do: :ok,
      else: {:error, field: :criteria, message: "contains invalid filter values"}
  end

  defp bounded_text?(value),
    do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= 256
end
