defmodule Orchestrator.Workflows.SavedFilter do
  use Ash.Resource,
    domain: Orchestrator.Workflows,
    data_layer: AshPostgres.DataLayer

  @allowed_keys MapSet.new(["assignee", "column", "label", "priority", "state", "text"])

  postgres do
    table("saved_filters")
    repo(Orchestrator.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:criteria, :map, allow_nil?: false, default: %{}, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :board, Orchestrator.Workflows.Board do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  identities do
    identity(:unique_filter_name_per_board, [:board_id, :name])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:board_id, :name, :criteria])
    end
  end

  validations do
    validate(fn changeset, _context ->
      criteria = Ash.Changeset.get_attribute(changeset, :criteria) || %{}
      unknown = Map.keys(criteria) |> MapSet.new() |> MapSet.difference(@allowed_keys)

      if MapSet.size(unknown) == 0,
        do: :ok,
        else: {:error, field: :criteria, message: "contains unsupported filter keys"}
    end)
  end
end
