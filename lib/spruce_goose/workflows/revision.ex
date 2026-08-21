defmodule SpruceGoose.Workflows.Revision do
  @moduledoc """
  A proposed change to one governed entity, and the record of who signed it off.

  The raw TOML body is stored on the row rather than referenced by path, so
  approval binds to *the bytes that were reviewed*. A file edited or deleted
  between propose and approve cannot change what gets applied, and
  `revise show` can always reproduce exactly what the approver saw.
  """

  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}
  alias SpruceGoose.Workflows.{RevisionState, RevisionTarget}

  postgres do
    table("revisions")
    repo(SpruceGoose.Repo)
  end

  # The proposer/approver split, stated where it cannot be routed around. An
  # actor holding only `proposer` can put a change up for review and take it
  # back, and nothing else.
  policies do
    policy action_type(:read) do
      authorize_if(Readable)
    end

    policy action([:propose, :withdraw]) do
      authorize_if(HasRole.proposer())
    end

    policy action(:approve) do
      authorize_if(HasRole.approver())
    end

    policy action_type(:destroy) do
      authorize_if(HasRole.approver())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:revision_id, :string, allow_nil?: false, public?: true)
    attribute(:target_kind, RevisionTarget, allow_nil?: false, public?: true)
    attribute(:target_id, :uuid, allow_nil?: false, public?: true)
    attribute(:target_ref, :string, allow_nil?: false, public?: true)

    # Denormalized from the target at propose time. A revision's scope is fixed
    # when it is proposed, not re-derived at approve time, and the flat column
    # is what lets a project-scoped reader's `revise list` filter rather than
    # walk to a target that may since have been removed.
    attribute(:project_key, :string, public?: true)

    attribute(:expect_lock_version, :integer, allow_nil?: false, public?: true)
    attribute(:change, :map, allow_nil?: false, default: %{}, public?: true)
    attribute(:reason, :string, allow_nil?: false, public?: true)
    attribute(:source_path, :string, allow_nil?: false, public?: true)

    # Byte-exact on purpose. Ash trims `:string` by default, which would drop
    # the trailing newline every editor writes — and then the stored body would
    # no longer hash to `source_digest`, so the thing that was signed off could
    # not be reproduced from the record.
    attribute(:source_body, :string,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:source_digest, :string, allow_nil?: false, public?: true)

    attribute(:state, RevisionState, allow_nil?: false, default: :pending, public?: true)

    attribute(:proposed_by, :string, allow_nil?: false, public?: true)
    attribute(:proposed_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:approved_by, :string, public?: true)
    attribute(:approved_at, :utc_datetime_usec, public?: true)
    attribute(:authorizing_task_id, :string, public?: true)
    attribute(:applied_lock_version, :integer, public?: true)

    # True only where a human deliberately signed off on their own proposal.
    # Recorded rather than merely permitted, so the audit trail distinguishes it.
    attribute(:self_approved, :boolean, allow_nil?: false, default: false, public?: true)

    attribute(:withdrawn_reason, :string, public?: true)
    attribute(:lock_version, :integer, allow_nil?: false, default: 1, public?: true)
    timestamps()
  end

  actions do
    defaults([:read])

    create :propose do
      primary?(true)

      accept([
        :revision_id,
        :target_kind,
        :target_id,
        :target_ref,
        :project_key,
        :expect_lock_version,
        :change,
        :reason,
        :source_path,
        :source_body,
        :source_digest,
        :proposed_by
      ])

      change(set_attribute(:state, :pending))
      change(set_attribute(:proposed_at, &DateTime.utc_now/0))
    end

    update :approve do
      require_atomic?(false)
      accept([:approved_by, :authorizing_task_id, :applied_lock_version, :self_approved])

      validate(fn changeset, _context -> require_pending(changeset) end)

      change(set_attribute(:state, :applied))
      change(set_attribute(:approved_at, &DateTime.utc_now/0))
      change(optimistic_lock(:lock_version))
    end

    update :withdraw do
      require_atomic?(false)
      accept([:withdrawn_reason])

      validate(fn changeset, _context -> require_pending(changeset) end)

      change(set_attribute(:state, :withdrawn))
      change(optimistic_lock(:lock_version))
    end

    destroy :destroy do
      primary?(true)
    end
  end

  identities do
    identity(:stable_revision_id, [:revision_id])
  end

  validations do
    validate(string_length(:reason, min: 1, max: 2_000))
    validate(string_length(:target_ref, min: 1, max: 512))
    validate(match(:source_digest, ~r/\A[0-9a-f]{64}\z/))
  end

  defp require_pending(changeset) do
    case changeset.data.state do
      :pending -> :ok
      state -> {:error, field: :state, message: "revision is already #{state}"}
    end
  end
end
