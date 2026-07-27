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
    attribute(:description, :string, public?: true)
    attribute(:rank, :string, public?: true)
    attribute(:priority, :integer, public?: true)
    attribute(:due_at, :utc_datetime_usec, public?: true)
    attribute(:assignees, {:array, :string}, allow_nil?: false, default: [], public?: true)
    attribute(:labels, {:array, :string}, allow_nil?: false, default: [], public?: true)
    attribute(:custom_fields, :map, allow_nil?: false, default: %{}, public?: true)
    attribute(:board_revision, :integer, allow_nil?: false, default: 1, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :workflow, Orchestrator.Workflows.Workflow do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :board, Orchestrator.Workflows.Board do
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :column, Orchestrator.Workflows.BoardColumn do
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
        :origin_event_id,
        :description,
        :board_id,
        :column_id,
        :rank,
        :priority,
        :due_at,
        :assignees,
        :labels,
        :custom_fields
      ])
    end

    update :revise do
      require_atomic?(false)
      accept([:title, :description, :definition_of_done, :runner, :input])
      change(optimistic_lock(:lock_version))
    end

    update :update_board_metadata do
      require_atomic?(false)

      accept([
        :board_id,
        :column_id,
        :rank,
        :priority,
        :due_at,
        :assignees,
        :labels,
        :custom_fields
      ])

      change(optimistic_lock(:board_revision))
    end

    update :transition do
      accept([])
      require_atomic?(false)
      argument(:to_state, Orchestrator.Workflows.TaskState, allow_nil?: false)
      argument(:reason, :string)

      validate(fn changeset, _context ->
        from = changeset.data.state
        to = Ash.Changeset.get_argument(changeset, :to_state)

        if Orchestrator.Workflows.Lifecycle.allowed?(from, to) do
          :ok
        else
          {:error, field: :state, message: "cannot transition from #{from} to #{to}"}
        end
      end)

      validate(fn changeset, _context ->
        task = changeset.data
        to = Ash.Changeset.get_argument(changeset, :to_state)
        reason = Ash.Changeset.get_argument(changeset, :reason)

        cond do
          to == :waiting and (not is_binary(reason) or String.trim(reason) == "") ->
            {:error, field: :reason, message: "is required when waiting"}

          to == :completed ->
            completion_requirements(task)

          true ->
            :ok
        end
      end)

      change(fn changeset, _context ->
        to = Ash.Changeset.get_argument(changeset, :to_state)
        reason = Ash.Changeset.get_argument(changeset, :reason)

        changeset
        |> Ash.Changeset.change_attribute(:state, to)
        |> maybe_store_reason(to, reason)
      end)

      change(optimistic_lock(:lock_version))
    end
  end

  validations do
    validate(string_length(:task_id, min: 1, max: 128))
    validate(string_length(:definition_of_done, min: 1, max: 2_000))

    validate(fn changeset, _context ->
      changeset
      |> Ash.Changeset.get_attribute(:custom_fields)
      |> valid_custom_fields()
    end)
  end

  defp valid_custom_fields(fields) when fields in [nil, %{}], do: :ok

  defp valid_custom_fields(fields) when is_map(fields) do
    if Enum.all?(fields, fn
         {_name, %{"type" => "string", "value" => value}} -> is_binary(value)
         {_name, %{"type" => "number", "value" => value}} -> is_number(value)
         {_name, %{"type" => "boolean", "value" => value}} -> is_boolean(value)
         {_name, %{"type" => "date", "value" => value}} -> is_binary(value)
         _ -> false
       end),
       do: :ok,
       else: {:error, field: :custom_fields, message: "contains an invalid typed value"}
  end

  defp valid_custom_fields(_fields),
    do: {:error, field: :custom_fields, message: "must be a map"}

  defp completion_requirements(task) do
    with :ok <- diagnosis_evidence(task),
         {:ok, todos} <-
           Ash.read(Ash.Query.filter_input(Orchestrator.Workflows.Todo, task_id: task.id)) do
      if Enum.all?(todos, & &1.completed) do
        :ok
      else
        {:error, field: :state, message: "all TODOs must be completed"}
      end
    end
  end

  defp diagnosis_evidence(%{task_type: :diagnosis, input: input}) do
    kinds =
      input
      |> Map.get("references", [])
      |> Enum.map(&Map.get(&1, "kind"))
      |> MapSet.new()

    missing = MapSet.difference(MapSet.new(["finding", "regression", "sop"]), kinds)

    if MapSet.size(missing) == 0 do
      :ok
    else
      {:error,
       field: :state, message: "diagnosis requires finding, regression, and sop references"}
    end
  end

  defp diagnosis_evidence(_task), do: :ok

  defp maybe_store_reason(changeset, target, reason)
       when target in [:waiting, :cancelled] and is_binary(reason) do
    key = if(target == :waiting, do: "wait_reason", else: "cancel_reason")
    Ash.Changeset.change_attribute(changeset, :input, Map.put(changeset.data.input, key, reason))
  end

  defp maybe_store_reason(changeset, _target, _reason), do: changeset
end
