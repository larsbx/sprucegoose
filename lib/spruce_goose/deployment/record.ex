defmodule SpruceGoose.Deployment.Record do
  @moduledoc """
  The one authoritative deployment record: desired state, lifecycle, and retention.

  The row is the current-state projection of the deployment's certified event
  stream (`deployment:<deployment_id>`); every column change here commits in
  the same transaction as the event that licenses it, and `last_event` names
  the head of that stream so parity is checkable at any time.
  """

  use Ash.Resource,
    domain: SpruceGoose.Deployment.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}
  alias SpruceGoose.Deployment.{Lifecycle, Release}

  postgres do
    table("deployments")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read), do: authorize_if(Readable)
    policy action(:create), do: authorize_if(HasRole.operator())

    policy action(:project) do
      authorize_if(HasRole.operator())
      authorize_if(HasRole.deployment_executor())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:deployment_id, :string, allow_nil?: false, public?: true)

    attribute(:environment, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: Lifecycle.environments()]
    )

    attribute(:requires_routing, :boolean, allow_nil?: false, default: false, public?: true)

    attribute(:state, :atom,
      allow_nil?: false,
      default: :queued,
      public?: true,
      constraints: [one_of: Lifecycle.states()]
    )

    attribute(:health_status, :atom,
      allow_nil?: false,
      default: :unknown,
      public?: true,
      constraints: [one_of: [:unknown, :healthy, :unhealthy]]
    )

    attribute(:health_detail, :string, public?: true)
    attribute(:cancellation_reason, :string, public?: true)
    attribute(:rollback_target_id, :string, public?: true)
    attribute(:pinned, :boolean, allow_nil?: false, default: false, public?: true)
    attribute(:terminal_at, :utc_datetime_usec, public?: true)
    attribute(:reclaimed_at, :utc_datetime_usec, public?: true)
    attribute(:last_event, :string, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :release, Release do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:release_id, :environment, :pinned])

      change(fn changeset, _context ->
        environment = Ash.Changeset.get_attribute(changeset, :environment)

        changeset
        |> Ash.Changeset.change_attribute(:deployment_id, SpruceGoose.PrefixedId.generate("dpl"))
        |> Ash.Changeset.change_attribute(
          :requires_routing,
          Lifecycle.requires_routing?(environment)
        )
      end)
    end

    # The projection update. Only the ledger writer calls this, inside the
    # transaction that appended the licensing event.
    update :project do
      require_atomic?(false)

      accept([
        :state,
        :health_status,
        :health_detail,
        :cancellation_reason,
        :rollback_target_id,
        :terminal_at,
        :reclaimed_at,
        :last_event
      ])
    end
  end

  identities do
    identity(:stable_deployment_id, [:deployment_id])
  end

  @doc "The shape the retention policy judges: identity, environment, state, dates, references."
  def to_retention(%{deployment_id: _} = record, project_key, active_references) do
    %{
      id: record.deployment_id,
      project: project_key,
      environment: record.environment,
      state: record.state,
      terminal_at: record.terminal_at,
      pinned: record.pinned,
      active_references: active_references
    }
  end
end
