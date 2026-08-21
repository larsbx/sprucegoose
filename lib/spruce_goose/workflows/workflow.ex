defmodule SpruceGoose.Workflows.Workflow do
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}
  alias SpruceGoose.Workflows.Definition

  postgres do
    table("workflows")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(Readable)
    end

    policy action([:create, :destroy]) do
      authorize_if(HasRole.author())
    end

    policy action(:rename) do
      authorize_if(HasRole.author())
    end

    policy action([:revise, :replace_definition]) do
      authorize_if(HasRole.approver())
    end

    policy action(:apply_blueprint) do
      authorize_if(HasRole.approver())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:workflow_id, :string, allow_nil?: false, public?: true)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:definition, Definition, allow_nil?: false, public?: true)
    attribute(:lock_version, :integer, allow_nil?: false, default: 1, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :roadmap, SpruceGoose.Workflows.Roadmap do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    has_many(:tasks, SpruceGoose.Workflows.Task)
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:roadmap_id, :workflow_id, :name, :definition])
    end

    create :apply_blueprint do
      accept([:roadmap_id, :workflow_id, :name, :definition])
    end

    update :replace_definition do
      accept([:definition])
      change(optimistic_lock(:lock_version))
    end

    # The governed-revision entry point: one action so a signed-off revision
    # can change the name and the DAG in a single versioned write rather than
    # two, which would leave a window where only half the revision had landed.
    # `workflow_id` is excluded on purpose: the vault references workflows by it.
    update :revise do
      accept([:name, :definition])
      change(optimistic_lock(:lock_version))
    end

    update :rename do
      accept([:name])
      change(optimistic_lock(:lock_version))
    end

    destroy :destroy do
      primary?(true)
    end
  end

  identities do
    identity(:unique_workflow_id_per_roadmap, [:roadmap_id, :workflow_id])
  end
end
