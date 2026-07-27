defmodule Orchestrator.Workflows.Task do
  use Ash.Resource,
    domain: Orchestrator.Workflows,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("workflow_tasks")
    repo(Orchestrator.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:task_id, :string, allow_nil?: false, public?: true)

    attribute(:task_type, Orchestrator.Workflows.TaskType,
      allow_nil?: false,
      default: :task,
      public?: true
    )

    attribute(:title, :string, allow_nil?: false, public?: true)
    attribute(:definition_of_done, :string, allow_nil?: false, public?: true)

    attribute(:state, Orchestrator.Workflows.TaskState,
      allow_nil?: false,
      default: :inbox,
      public?: true
    )

    attribute(:runner, Orchestrator.Workflows.TaskKind, allow_nil?: false, public?: true)
    attribute(:input, :map, allow_nil?: false, default: %{}, public?: true)
    attribute(:origin_event_id, :string, public?: true)
    attribute(:lock_version, :integer, allow_nil?: false, default: 1, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :workflow, Orchestrator.Workflows.Workflow do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    has_many :todos, Orchestrator.Workflows.Todo do
      destination_attribute(:task_id)
    end

    has_many :predecessor_edges, Orchestrator.Workflows.Dependency do
      destination_attribute(:successor_id)
    end

    has_many :successor_edges, Orchestrator.Workflows.Dependency do
      destination_attribute(:predecessor_id)
    end
  end

  identities do
    identity(:stable_task_id, [:task_id])
    identity(:idempotent_origin_event, [:origin_event_id], nils_distinct?: true)
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)

      accept([
        :workflow_id,
        :task_id,
        :task_type,
        :title,
        :definition_of_done,
        :runner,
        :input,
        :origin_event_id
      ])
    end

    update :revise do
      accept([:title, :definition_of_done, :runner, :input])
      change(optimistic_lock(:lock_version))
    end

    update :transition do
      accept([])
      require_atomic?(false)
      argument(:to_state, Orchestrator.Workflows.TaskState, allow_nil?: false)

      validate(fn changeset, _context ->
        from = changeset.data.state
        to = Ash.Changeset.get_argument(changeset, :to_state)

        if Orchestrator.Workflows.Lifecycle.allowed?(from, to) do
          :ok
        else
          {:error, field: :state, message: "cannot transition from #{from} to #{to}"}
        end
      end)

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(
          changeset,
          :state,
          Ash.Changeset.get_argument(changeset, :to_state)
        )
      end)

      change(optimistic_lock(:lock_version))
    end
  end

  validations do
    validate(string_length(:task_id, min: 1, max: 128))
    validate(string_length(:definition_of_done, min: 1, max: 2_000))
  end
end
