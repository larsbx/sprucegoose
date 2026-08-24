defmodule SpruceGoose.Workflows.VerificationTarget do
  @moduledoc """
  A declared destination that completion claims can be probed against.

  Targets exist so that host identity is *data* rather than a literal embedded
  in check logic. A claim binds to a target by `key`, so the same detection
  runs unchanged against Papa, Mama, or a future deployment: re-point the
  target, and every claim that references it follows.

  This resource deliberately stores only *how to reach* a destination. It does
  not store credentials, and it does not execute anything.
  """
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}
  alias SpruceGoose.Workflows.AccessMethod

  postgres do
    table("verification_targets")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(Readable)
    end

    policy action_type([:create, :update]) do
      authorize_if(HasRole.operator())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:key, :string, allow_nil?: false, public?: true)
    attribute(:description, :string, public?: true)
    attribute(:access_method, AccessMethod, allow_nil?: false, public?: true)

    # An address is an opaque handle interpreted by the external runner: an ssh
    # alias, a container name, a local marker. Never a credential.
    attribute(:address, :string, allow_nil?: false, public?: true)

    attribute(:retired, :boolean, allow_nil?: false, default: false, public?: true)

    timestamps()
  end

  actions do
    defaults([:read])

    create :declare do
      primary?(true)
      accept([:key, :description, :access_method, :address])
    end

    # Targets are retired rather than deleted, so historical claims keep
    # resolving to the destination they were actually probed against.
    update :retire do
      require_atomic?(false)
      accept([])
      change(set_attribute(:retired, true))
    end

    update :repoint do
      require_atomic?(false)
      accept([:address, :description])
    end
  end

  identities do
    identity(:unique_key, [:key])
  end
end
