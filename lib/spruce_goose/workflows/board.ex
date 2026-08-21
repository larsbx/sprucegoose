defmodule SpruceGoose.Workflows.Board do
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}

  postgres do
    table("boards")
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
    attribute(:lock_version, :integer, allow_nil?: false, default: 1, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :workflow, SpruceGoose.Workflows.Workflow do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    has_many(:columns, SpruceGoose.Workflows.BoardColumn)
    has_many(:tasks, SpruceGoose.Workflows.Task)
    has_many(:saved_filters, SpruceGoose.Workflows.SavedFilter)
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:workflow_id, :key, :name])
    end

    # `rename` and `revise` accept the same field but not the same authority:
    # renaming is ordinary structural upkeep, revising arrives through a signed
    # off proposal. One action serving both would collapse that distinction.
    update :rename do
      accept([:name])
      change(optimistic_lock(:lock_version))
    end

    update :revise do
      accept([:name])
      change(optimistic_lock(:lock_version))
    end

    destroy :destroy do
      primary?(true)
    end
  end

  identities do
    identity(:unique_board_key_per_workflow, [:workflow_id, :key])
  end
end
