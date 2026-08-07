defmodule SpruceGoose.Workflows.BoardColumn do
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}

  postgres do
    table("board_columns")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(Readable)
    end

    policy action_type([:create, :destroy]) do
      authorize_if(HasRole.author())
    end

    policy action(:rename) do
      authorize_if(HasRole.author())
    end

    policy action(:revise) do
      authorize_if(HasRole.approver())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:key, :string, allow_nil?: false, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:position, :integer, allow_nil?: false, public?: true)
    attribute(:task_state, SpruceGoose.Workflows.TaskState, allow_nil?: false, public?: true)
    attribute(:lock_version, :integer, allow_nil?: false, default: 1, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :board, SpruceGoose.Workflows.Board do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    has_many :tasks, SpruceGoose.Workflows.Task do
      destination_attribute(:column_id)
    end
  end

  actions do
    defaults([:read])

    update :rename do
      accept([:name])
      change(optimistic_lock(:lock_version))
    end

    update :revise do
      accept([:name, :position])
      change(optimistic_lock(:lock_version))
    end

    destroy :destroy do
      primary?(true)
    end

    create :create do
      primary?(true)
      accept([:board_id, :key, :name, :position, :task_state])
    end
  end

  identities do
    identity(:unique_column_key_per_board, [:board_id, :key])
    identity(:unique_column_position_per_board, [:board_id, :position])
    identity(:unique_column_state_per_board, [:board_id, :task_state])
  end
end
