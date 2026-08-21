defmodule SpruceGoose.Workflows.TodoDependency do
  @moduledoc """
  Explicit predecessor edge between two TODOs under the same task.

  TODOs default to fully concurrent: absence of an edge is absence of a
  constraint. Sequential sections are chains of edges; concurrent sections are
  siblings with no edge between them. This mirrors task_dependencies one level
  down, so partial order is expressed the same way at every level.

  Position remains presentational. Ordering semantics live here.
  """
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}

  postgres do
    table("task_todo_dependencies")
    repo(SpruceGoose.Repo)

    check_constraints do
      check_constraint([:predecessor_id, :successor_id], "todo_not_self_dependency",
        check: "predecessor_id <> successor_id",
        message: "a TODO cannot depend on itself"
      )
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Readable)
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(HasRole.operator())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:task_id, :uuid, allow_nil?: false, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :predecessor, SpruceGoose.Workflows.Todo do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :successor, SpruceGoose.Workflows.Todo do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:task_id, :predecessor_id, :successor_id])
    end

    destroy :destroy do
      primary?(true)
    end
  end

  identities do
    identity(:unique_todo_dependency, [:predecessor_id, :successor_id])
  end
end
