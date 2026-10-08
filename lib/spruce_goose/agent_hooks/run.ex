defmodule SpruceGoose.AgentHooks.Run do
  @moduledoc "Immutable input envelope; delivery bookkeeping lives in a separate table."
  use Ash.Resource,
    domain: SpruceGoose.AgentHooks,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("agent_hook_runs")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read), do: authorize_if(SpruceGoose.Checks.Readable)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:run_key, :string, allow_nil?: false, public?: true)
    attribute(:event_id, :uuid, allow_nil?: false, public?: true)
    attribute(:event_key, :string, allow_nil?: false, public?: true)
    attribute(:hook_id, :string, allow_nil?: false, public?: true)
    attribute(:hook_version, :integer, allow_nil?: false, public?: true)
    attribute(:actor_id, :uuid, allow_nil?: false, public?: true)
    attribute(:config_digest, :string, allow_nil?: false, public?: true)
    attribute(:charter_digest, :string, allow_nil?: false, public?: true)
    attribute(:context_digest, :string, allow_nil?: false, public?: true)
    attribute(:context, :map, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :inbox_item, SpruceGoose.Workflows.InboxItem do
      allow_nil?(false)
      public?(true)
    end
  end

  actions do
    defaults([:read])
  end

  identities do
    identity(:stable_run_key, [:run_key])
  end
end
