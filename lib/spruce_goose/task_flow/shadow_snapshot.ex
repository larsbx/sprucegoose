defmodule SpruceGoose.TaskFlow.ShadowSnapshot do
  @moduledoc "Immutable shadow of one revision of TaskFlow-owned resumability state."

  use Ash.Resource,
    domain: SpruceGoose.TaskFlow.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}
  alias SpruceGoose.Workflows.Task

  postgres do
    table("taskflow_shadow_snapshots")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read), do: authorize_if(Readable)
    policy action(:import), do: authorize_if(HasRole.operator())
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:flow_id, :string, allow_nil?: false, public?: true)
    attribute(:revision, :integer, allow_nil?: false, public?: true)
    attribute(:sync_mode, :string, allow_nil?: false, public?: true)
    attribute(:status, :string, allow_nil?: false, public?: true)
    attribute(:owner_key, :string, allow_nil?: false, public?: true)
    attribute(:current_step, :string, public?: true)
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
        :flow_id,
        :revision,
        :sync_mode,
        :status,
        :owner_key,
        :current_step,
        :state_digest,
        :wait_digest,
        :child_task_count
      ])
    end
  end

  identities do
    identity(:one_snapshot_per_revision, [:flow_id, :revision])
  end

  validations do
    validate(compare(:revision, greater_than_or_equal_to: 0))
    validate(compare(:child_task_count, greater_than_or_equal_to: 0))
    validate(match(:state_digest, ~r/\Asha256:[0-9a-f]{64}\z/))
    validate(match(:wait_digest, ~r/\Asha256:[0-9a-f]{64}\z/))
    validate(string_length(:flow_id, min: 1, max: 128))
    validate(string_length(:owner_key, min: 1, max: 512))
    validate(string_length(:current_step, max: 512))
  end
end
