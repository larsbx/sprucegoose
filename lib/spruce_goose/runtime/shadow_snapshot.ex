defmodule SpruceGoose.Runtime.ShadowSnapshot do
  @moduledoc "Immutable provider-neutral shadow of one external runtime revision."

  use Ash.Resource,
    domain: SpruceGoose.Runtime.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}
  alias SpruceGoose.Workflows.Task

  postgres do
    table("runtime_shadow_snapshots")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read), do: authorize_if(Readable)
    policy action(:import), do: authorize_if(HasRole.operator())
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:protocol_version, :integer, allow_nil?: false, default: 1, public?: true)
    attribute(:adapter, :string, allow_nil?: false, public?: true)
    attribute(:external_id, :string, allow_nil?: false, public?: true)
    attribute(:revision, :integer, allow_nil?: false, public?: true)

    attribute(:status, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: ~w(pending running waiting blocked succeeded failed cancelled)a]
    )

    attribute(:checkpoint, :string, public?: true)
    attribute(:owner_context_digest, :string, allow_nil?: false, public?: true)
    attribute(:state_digest, :string, allow_nil?: false, public?: true)
    attribute(:wait_digest, :string, allow_nil?: false, public?: true)
    attribute(:child_task_count, :integer, allow_nil?: false, public?: true)
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

    create :import do
      accept([
        :task_id,
        :protocol_version,
        :adapter,
        :external_id,
        :revision,
        :status,
        :checkpoint,
        :owner_context_digest,
        :state_digest,
        :wait_digest,
        :child_task_count
      ])
    end
  end

  identities do
    identity(:one_snapshot_per_revision, [:adapter, :external_id, :revision])
  end

  validations do
    validate(compare(:protocol_version, greater_than_or_equal_to: 1))
    validate(compare(:revision, greater_than_or_equal_to: 0))
    validate(compare(:child_task_count, greater_than_or_equal_to: 0))
    validate(match(:owner_context_digest, ~r/\Asha256:[0-9a-f]{64}\z/))
    validate(match(:state_digest, ~r/\Asha256:[0-9a-f]{64}\z/))
    validate(match(:wait_digest, ~r/\Asha256:[0-9a-f]{64}\z/))
    validate(string_length(:adapter, min: 1, max: 128))
    validate(string_length(:external_id, min: 1, max: 256))
    validate(string_length(:checkpoint, max: 512))
  end
end
