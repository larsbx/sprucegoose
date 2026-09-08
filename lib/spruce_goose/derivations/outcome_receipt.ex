defmodule SpruceGoose.Derivations.OutcomeReceipt do
  @moduledoc "Append-only certified terminal outcome for one immutable derivation permit."

  use Ash.Resource,
    domain: SpruceGoose.Derivations.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}
  alias SpruceGoose.Workflows.Task

  postgres do
    table("derivation_outcome_receipts")
    repo(SpruceGoose.Repo)
    identity_index_names(one_terminal_receipt_per_permit: "derivation_receipts_one_permit_idx")
  end

  policies do
    # `HasRole` resolves its subject from a changeset, so on a read action it can
    # never match — the clause that used to sit here read as "or a derivation
    # executor may read any receipt" and authorized nothing. `Readable` already
    # covers the executor: every grant implies :reader within its own scope.
    policy action_type(:read), do: authorize_if(Readable)

    policy action(:record), do: authorize_if(HasRole.derivation_executor())
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:receipt_id, :string, allow_nil?: false, public?: true)
    attribute(:permit_id, :string, allow_nil?: false, public?: true)
    attribute(:executor_id, :string, allow_nil?: false, public?: true)

    attribute(:outcome, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:succeeded, :failed]]
    )

    attribute(:evidence_digest, :string, public?: true)
    attribute(:artifact_digest, :string, public?: true)
    attribute(:failure_reason, :string, public?: true)
    attribute(:roots, :map, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :task, Task do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :record do
      accept([
        :task_id,
        :receipt_id,
        :permit_id,
        :executor_id,
        :outcome,
        :evidence_digest,
        :artifact_digest,
        :failure_reason,
        :roots
      ])
    end
  end

  identities do
    identity(:stable_receipt_id, [:receipt_id])
    identity(:one_terminal_receipt_per_permit, [:permit_id])
  end
end
