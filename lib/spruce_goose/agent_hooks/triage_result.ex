defmodule SpruceGoose.AgentHooks.TriageResult do
  @moduledoc "One immutable proposal, refusal, or failure per agent run."
  use Ash.Resource,
    domain: SpruceGoose.AgentHooks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.AgentHooks.{Proposal, Store}
  alias SpruceGoose.Checks.{HasRole, Readable}

  postgres do
    table("inbox_triage_results")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read), do: authorize_if(Readable)
    policy action(:submit), do: authorize_if(HasRole.proposer())
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:actor_id, :uuid, allow_nil?: false, public?: true)
    attribute(:context_digest, :string, allow_nil?: false, public?: true)

    attribute(:outcome, :atom,
      allow_nil?: false,
      default: :proposed,
      public?: true,
      constraints: [one_of: [:proposed, :refused, :failed]]
    )

    attribute(:proposal, :map, public?: true)
    attribute(:proposal_digest, :string, public?: true)
    attribute(:reason, :string, public?: true)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :run, SpruceGoose.AgentHooks.Run do
      allow_nil?(false)
      public?(true)
      attribute_writable?(true)
    end
  end

  actions do
    defaults([:read])

    create :submit do
      accept([:run_id, :proposal])
      argument(:claim_id, :uuid, allow_nil?: false)

      validate(fn changeset, _ ->
        Proposal.validate(Ash.Changeset.get_attribute(changeset, :proposal))
      end)

      change(fn changeset, context ->
        changeset
        |> Ash.Changeset.before_action(&Store.prepare_submission(&1, context.actor))
        |> Ash.Changeset.after_action(fn changeset, result ->
          Store.complete_delivery(Ash.Changeset.get_attribute(changeset, :run_id))
          {:ok, result}
        end)
      end)
    end
  end

  identities do
    identity(:one_result_per_run, [:run_id])
  end
end
