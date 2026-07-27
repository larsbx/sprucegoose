defmodule Orchestrator.Workflows.Todo do
  use Ash.Resource,
    domain: Orchestrator.Workflows,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("task_todos")
    repo(Orchestrator.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:todo_id, :string, allow_nil?: false, public?: true)
    attribute(:body, :string, allow_nil?: false, public?: true)
    attribute(:position, :integer, allow_nil?: false, public?: true)
    attribute(:completed, :boolean, allow_nil?: false, default: false, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :task, Orchestrator.Workflows.Task do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  identities do
    identity(:stable_todo_per_task, [:task_id, :todo_id])
    identity(:stable_position_per_task, [:task_id, :position])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:task_id, :todo_id, :body, :position])
    end

    update :complete do
      accept([])
      change(set_attribute(:completed, true))
    end
  end
end
