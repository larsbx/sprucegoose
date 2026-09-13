defmodule SpruceGoose.Deployment.Revocation do
  @moduledoc """
  Append-only revocation of an issued, unspent authorization.

  An authorization row is immutable, so withdrawing one before it expires is
  a second immutable fact keyed by the same identifier. `request/2` refuses a
  revoked authorization exactly as it refuses a spent or expired one.
  """

  use Ash.Resource,
    domain: SpruceGoose.Deployment.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}
  alias SpruceGoose.Deployment.Authorization

  postgres do
    table("deployment_authorization_revocations")
    repo(SpruceGoose.Repo)

    identity_index_names(
      one_revocation_per_authorization: "deployment_revocations_one_per_authorization_idx"
    )
  end

  policies do
    policy action_type(:read), do: authorize_if(Readable)
    policy action(:revoke), do: authorize_if(HasRole.approver())
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:authorization_id, :string, allow_nil?: false, public?: true)
    attribute(:revoked_by, :string, allow_nil?: false, public?: true)
    attribute(:reason, :string, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :authorization, Authorization do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
      source_attribute(:authorization_record_id)
    end
  end

  actions do
    defaults([:read])

    create :revoke do
      accept([:authorization_record_id, :authorization_id, :reason])
      validate(present(:reason))

      change(fn changeset, context ->
        Ash.Changeset.change_attribute(changeset, :revoked_by, context.actor.name)
      end)
    end
  end

  identities do
    identity(:one_revocation_per_authorization, [:authorization_id])
  end
end
