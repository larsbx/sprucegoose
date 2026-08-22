defmodule SpruceGoose.Workflows.Roadmap do
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}
  alias SpruceGoose.Workflows.ConstitutiveMutation

  postgres do
    table("roadmaps")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(Readable)
    end

    policy action([:create, :destroy]) do
      authorize_if(HasRole.author())
    end

    policy action(:apply_blueprint) do
      authorize_if(HasRole.approver())
    end

    policy action(:apply_blueprint_revision) do
      authorize_if(HasRole.approver())
    end

    policy action(:rename) do
      authorize_if(HasRole.author())
    end

    # `:revise` is only ever reached through an approved revision, so it carries
    # the approver role rather than author's.
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
    belongs_to :project, SpruceGoose.Workflows.Project do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    has_many(:workflows, SpruceGoose.Workflows.Workflow)
  end

  actions do
    defaults([:read])

    update :rename do
      require_atomic?(false)
      accept([:name])
      change(optimistic_lock(:lock_version))
      validate(fn _changeset, _context -> ConstitutiveMutation.validate_legacy() end)
    end

    # Identical to :rename today, because the row is only key + name — a
    # roadmap's substance lives in the vault Markdown. It exists separately so
    # every governed revision applies through one uniformly named action, and
    # so the audit trail distinguishes a signed-off revision from a rename.
    # `key` is excluded on purpose: the vault references roadmaps by key.
    update :revise do
      require_atomic?(false)
      accept([:name])
      change(optimistic_lock(:lock_version))
      validate(fn _changeset, _context -> ConstitutiveMutation.validate_legacy() end)
    end

    update :apply_blueprint_revision do
      accept([:name])
      change(optimistic_lock(:lock_version))
    end

    destroy :destroy do
      primary?(true)
      require_atomic?(false)
      validate(fn _changeset, _context -> ConstitutiveMutation.validate_legacy() end)
    end

    create :create do
      primary?(true)
      accept([:project_id, :key, :name])
      validate(fn _changeset, _context -> ConstitutiveMutation.validate_legacy() end)
    end

    create :apply_blueprint do
      accept([:project_id, :key, :name])
    end
  end

  identities do
    identity(:unique_roadmap_key_per_project, [:project_id, :key])
  end
end
