defmodule Orchestrator.Workflows.Dependency do
  use Ash.Resource,
    domain: Orchestrator.Workflows,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("task_dependencies")
    repo(Orchestrator.Repo)

    check_constraints do
      check_constraint([:predecessor_id, :successor_id], "not_self_dependency",
        check: "predecessor_id <> successor_id",
        message: "a task cannot depend on itself"
      )
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:workflow_id, :uuid, public?: true, writable?: false)
    attribute(:source, :string, allow_nil?: false, default: "native", public?: true)
    timestamps()
  end

  relationships do
    belongs_to :predecessor, Orchestrator.Workflows.Task do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :successor, Orchestrator.Workflows.Task do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  identities do
    identity(:unique_dependency, [:predecessor_id, :successor_id])
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:predecessor_id, :successor_id, :source])
    end
  end
end
