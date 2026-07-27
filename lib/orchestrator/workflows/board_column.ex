defmodule Orchestrator.Workflows.BoardColumn do
  use Ash.Resource,
    domain: Orchestrator.Workflows,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("board_columns")
    repo(Orchestrator.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:key, :string, allow_nil?: false, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:position, :integer, allow_nil?: false, public?: true)
    attribute(:task_state, Orchestrator.Workflows.TaskState, allow_nil?: false, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :board, Orchestrator.Workflows.Board do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    has_many :tasks, Orchestrator.Workflows.Task do
      destination_attribute(:column_id)
    end
  end

  identities do
    identity(:unique_column_key_per_board, [:board_id, :key])
    identity(:unique_column_position_per_board, [:board_id, :position])
    identity(:unique_column_state_per_board, [:board_id, :task_state])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:board_id, :key, :name, :position, :task_state])
    end
  end
end
