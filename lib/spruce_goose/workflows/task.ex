defmodule SpruceGoose.Workflows.Task do
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}

  postgres do
    table("workflow_tasks")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(Readable)
    end

    # Admitting and driving work is the operator's whole job — this is the bulk
    # of what an agent does, and is deliberately distinct from being allowed to
    # revise what the work says.
    policy action_type([:create, :destroy]) do
      authorize_if(HasRole.operator())
    end

    policy action([
             :transition,
             :move,
             :update_board_metadata,
             :acknowledge_sop,
             :record_artifact_receipt
           ]) do
      authorize_if(HasRole.operator())
    end

    policy action(:revise) do
      authorize_if(HasRole.approver())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:task_id, :string, allow_nil?: false, public?: true)

    attribute(:task_type, SpruceGoose.Workflows.TaskType,
      allow_nil?: false,
      default: :task,
      public?: true
    )

    attribute(:title, :string, allow_nil?: false, public?: true)
    attribute(:definition_of_done, :string, allow_nil?: false, public?: true)
    attribute(:sop_gate_required, :boolean, allow_nil?: false, default: true, public?: true)
    attribute(:sop_id, :string, public?: true)
    attribute(:sop_path, :string, public?: true)
    attribute(:sop_digest, :string, public?: true)

    # Nullable because null *is* the grandfathered state: every acknowledgment
    # taken before the SOP declared a version carries none, and must stay
    # representable rather than being backfilled with a version nobody read.
    attribute(:sop_version, :string, public?: true)
    attribute(:sop_acknowledged_at, :utc_datetime_usec, public?: true)

    attribute(:state, SpruceGoose.Workflows.TaskState,
      allow_nil?: false,
      default: :inbox,
      public?: true
    )

    attribute(:runner, SpruceGoose.Workflows.TaskKind, allow_nil?: false, public?: true)
    attribute(:input, :map, allow_nil?: false, default: %{}, public?: true)

    attribute(:artifact_requirements, {:array, :string},
      allow_nil?: false,
      default: [],
      public?: true
    )

    attribute(:artifact_receipts, {:array, :map}, allow_nil?: false, default: [], public?: true)
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
    belongs_to :workflow, SpruceGoose.Workflows.Workflow do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :board, SpruceGoose.Workflows.Board do
      attribute_writable?(true)
      public?(true)
    end

    belongs_to :column, SpruceGoose.Workflows.BoardColumn do
      attribute_writable?(true)
      public?(true)
    end

    has_many :todos, SpruceGoose.Workflows.Todo do
      destination_attribute(:task_id)
    end

    has_many :predecessor_edges, SpruceGoose.Workflows.Dependency do
      destination_attribute(:successor_id)
    end

    has_many :successor_edges, SpruceGoose.Workflows.Dependency do
      destination_attribute(:predecessor_id)
    end
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
        :artifact_requirements,
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

      change(fn changeset, _context -> acknowledge_sop(changeset) end)
    end

    update :revise do
      require_atomic?(false)
      accept([:title, :description, :definition_of_done, :runner, :input])
      change(optimistic_lock(:lock_version))
    end

    update :record_artifact_receipt do
      require_atomic?(false)
      accept([:artifact_receipts])

      validate(fn changeset, _context ->
        if changeset.data.state in [:inbox, :proposed, :queued],
          do: :ok,
          else: {:error, field: :artifact_receipts, message: "are immutable after readiness"}
      end)

      change(optimistic_lock(:lock_version))
    end

    update :acknowledge_sop do
      require_atomic?(false)
      accept([])
      change(fn changeset, _context -> acknowledge_sop(changeset) end)
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

    update :move do
      require_atomic?(false)
      accept([:board_id, :column_id, :rank])
      argument(:to_state, SpruceGoose.Workflows.TaskState, allow_nil?: false)

      validate(fn changeset, _context ->
        from = changeset.data.state
        to = Ash.Changeset.get_argument(changeset, :to_state)

        if from == to or SpruceGoose.Workflows.Lifecycle.allowed?(from, to),
          do: :ok,
          else: {:error, field: :state, message: "cannot transition from #{from} to #{to}"}
      end)

      validate(fn changeset, _context -> validate_start(changeset) end)
      validate(fn changeset, _context -> validate_artifact_readiness(changeset) end)
      validate(fn changeset, _context -> validate_predecessors(changeset) end)

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(
          changeset,
          :state,
          Ash.Changeset.get_argument(changeset, :to_state)
        )
      end)

      change(optimistic_lock(:lock_version))
      change(optimistic_lock(:board_revision))
    end

    update :transition do
      accept([])
      require_atomic?(false)
      argument(:to_state, SpruceGoose.Workflows.TaskState, allow_nil?: false)
      argument(:reason, :string)

      validate(fn changeset, _context ->
        from = changeset.data.state
        to = Ash.Changeset.get_argument(changeset, :to_state)

        if SpruceGoose.Workflows.Lifecycle.allowed?(from, to) do
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
          to in [:waiting, :cancelled] and
              (not is_binary(reason) or String.trim(reason) == "") ->
            {:error, field: :reason, message: "is required when waiting or cancelling"}

          to == :completed ->
            completion_requirements(task)

          true ->
            :ok
        end
      end)

      validate(fn changeset, _context -> validate_start(changeset) end)
      validate(fn changeset, _context -> validate_artifact_readiness(changeset) end)
      validate(fn changeset, _context -> validate_predecessors(changeset) end)

      change(fn changeset, _context ->
        to = Ash.Changeset.get_argument(changeset, :to_state)
        reason = Ash.Changeset.get_argument(changeset, :reason)

        changeset
        |> Ash.Changeset.change_attribute(:state, to)
        |> align_board_column(to)
        |> maybe_store_reason(to, reason)
      end)

      change(optimistic_lock(:lock_version))
    end
  end

  identities do
    identity(:stable_task_id, [:task_id])
    identity(:idempotent_origin_event, [:origin_event_id], nils_distinct?: true)
  end

  validations do
    validate(string_length(:task_id, min: 1, max: 128))
    validate(string_length(:definition_of_done, min: 1, max: 2_000))
    validate(fn changeset, _context -> valid_sop_gate(changeset) end)

    validate(fn changeset, _context ->
      changeset
      |> Ash.Changeset.get_attribute(:custom_fields)
      |> valid_custom_fields()
    end)

    validate(fn changeset, _context -> valid_board_metadata(changeset) end)
    validate(fn changeset, _context -> valid_artifacts(changeset) end)
  end

  defp valid_custom_fields(fields) when fields in [nil, %{}], do: :ok

  defp valid_custom_fields(fields) when is_map(fields) do
    if Enum.all?(fields, fn
         {_name, %{"type" => "string", "value" => value}} -> is_binary(value)
         {_name, %{"type" => "number", "value" => value}} -> is_number(value)
         {_name, %{"type" => "boolean", "value" => value}} -> is_boolean(value)
         {_name, %{"type" => "date", "value" => value}} -> valid_date?(value)
         _ -> false
       end),
       do: :ok,
       else: {:error, field: :custom_fields, message: "contains an invalid typed value"}
  end

  defp valid_custom_fields(_fields),
    do: {:error, field: :custom_fields, message: "must be a map"}

  defp valid_sop_gate(changeset) do
    required = Ash.Changeset.get_attribute(changeset, :sop_gate_required)
    id = Ash.Changeset.get_attribute(changeset, :sop_id)
    path = Ash.Changeset.get_attribute(changeset, :sop_path)
    digest = Ash.Changeset.get_attribute(changeset, :sop_digest)
    version = Ash.Changeset.get_attribute(changeset, :sop_version)
    acknowledged_at = Ash.Changeset.get_attribute(changeset, :sop_acknowledged_at)

    cond do
      required == false ->
        :ok

      # nil is the grandfathered state and stays valid; a recorded version that
      # is not semver could never be compared, so it is refused at the door.
      not is_nil(version) and match?(:error, Version.parse(version)) ->
        {:error, field: :sop_version, message: "must be semantic versioning"}

      id != SpruceGoose.SopGate.id() ->
        {:error, field: :sop_id, message: "must identify the Systemwide SOP"}

      not (is_binary(path) and String.trim(path) != "") ->
        {:error, field: :sop_path, message: "must record the configured Systemwide SOP path"}

      not (is_binary(digest) and Regex.match?(~r/^[0-9a-f]{64}$/, digest)) ->
        {:error, field: :sop_digest, message: "must be a lowercase SHA-256 digest"}

      is_nil(acknowledged_at) ->
        {:error, field: :sop_acknowledged_at, message: "is required"}

      true ->
        :ok
    end
  end

  defp valid_date?(value) when is_binary(value), do: match?({:ok, _}, Date.from_iso8601(value))
  defp valid_date?(_value), do: false

  defp acknowledge_sop(changeset) do
    case SpruceGoose.SopGate.acknowledge(SpruceGoose.SopGate.path()) do
      {:ok, acknowledgment} ->
        Enum.reduce(acknowledgment, changeset, fn {attribute, value}, current ->
          Ash.Changeset.change_attribute(current, attribute, value)
        end)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :sop_path, message: message)
    end
  end

  defp validate_start(changeset) do
    if changeset.data.state == :ready and
         Ash.Changeset.get_argument(changeset, :to_state) == :in_progress,
       do: SpruceGoose.SopGate.verify(changeset.data),
       else: :ok
  end

  defp validate_artifact_readiness(changeset) do
    if Ash.Changeset.get_argument(changeset, :to_state) == :ready do
      requirements = changeset.data.artifact_requirements || []
      receipts = changeset.data.artifact_receipts || []
      received = MapSet.new(receipts, &Map.get(&1, "name"))
      missing = Enum.reject(requirements, &MapSet.member?(received, &1))

      if missing == [],
        do: :ok,
        else:
          {:error,
           field: :artifact_receipts,
           message: "missing verified receipts for: #{Enum.join(missing, ", ")}"}
    else
      :ok
    end
  end

  defp valid_artifacts(changeset) do
    requirements = Ash.Changeset.get_attribute(changeset, :artifact_requirements) || []
    receipts = Ash.Changeset.get_attribute(changeset, :artifact_receipts) || []

    cond do
      requirements != Enum.uniq(requirements) or not Enum.all?(requirements, &bounded_name?/1) ->
        {:error, field: :artifact_requirements, message: "must be unique bounded names"}

      not Enum.all?(receipts, &valid_artifact_receipt?/1) ->
        {:error,
         field: :artifact_receipts, message: "must contain verified immutable receipt fields"}

      Enum.any?(receipts, &(Map.get(&1, "name") not in requirements)) ->
        {:error, field: :artifact_receipts, message: "must match a declared artifact requirement"}

      receipts |> Enum.map(&Map.get(&1, "name")) |> Enum.uniq() |> length() != length(receipts) ->
        {:error, field: :artifact_receipts, message: "must contain one receipt per artifact"}

      true ->
        :ok
    end
  end

  defp valid_artifact_receipt?(receipt) when is_map(receipt) do
    with name when is_binary(name) <- Map.get(receipt, "name"),
         digest when is_binary(digest) <- Map.get(receipt, "sha256"),
         size when is_integer(size) and size >= 0 <- Map.get(receipt, "size_bytes"),
         locator when is_binary(locator) <- Map.get(receipt, "storage_locator"),
         source when is_binary(source) <- Map.get(receipt, "source_identity"),
         verifier when is_binary(verifier) <- Map.get(receipt, "retrieval_verifier"),
         verified_at when is_binary(verified_at) <- Map.get(receipt, "retrieval_verified_at"),
         true <- bounded_name?(name),
         true <- Regex.match?(~r/^[0-9a-f]{64}$/, digest),
         true <- String.trim(locator) != "",
         true <- String.trim(source) != "",
         true <- String.trim(verifier) != "",
         {:ok, _date, 0} <- DateTime.from_iso8601(verified_at) do
      true
    else
      _ -> false
    end
  end

  defp valid_artifact_receipt?(_), do: false

  defp validate_predecessors(changeset) do
    if Ash.Changeset.get_argument(changeset, :to_state) == :in_progress do
      sql = """
      SELECT 1
      FROM task_dependencies AS dependency
      JOIN workflow_tasks AS predecessor ON predecessor.id = dependency.predecessor_id
      WHERE dependency.successor_id = $1::text::uuid
        AND predecessor.state <> 'completed'
      LIMIT 1
      """

      # AUTHORIZATION: Ash change validation; the enclosing action carries the actor.
      case Ecto.Adapters.SQL.query!(SpruceGoose.Repo, sql, [changeset.data.id]).rows do
        [] -> :ok
        _ -> {:error, field: :state, message: "task has incomplete predecessors"}
      end
    else
      :ok
    end
  end

  defp valid_board_metadata(changeset) do
    board_id = Ash.Changeset.get_attribute(changeset, :board_id)
    column_id = Ash.Changeset.get_attribute(changeset, :column_id)

    workflow_id =
      Ash.Changeset.get_attribute(changeset, :workflow_id) || changeset.data.workflow_id

    state = Ash.Changeset.get_attribute(changeset, :state) || changeset.data.state
    rank = Ash.Changeset.get_attribute(changeset, :rank)
    priority = Ash.Changeset.get_attribute(changeset, :priority)
    assignees = Ash.Changeset.get_attribute(changeset, :assignees) || []
    labels = Ash.Changeset.get_attribute(changeset, :labels) || []
    fields = Ash.Changeset.get_attribute(changeset, :custom_fields) || %{}

    cond do
      priority != nil and priority not in 0..5 ->
        {:error, field: :priority, message: "must be between 0 and 5"}

      rank != nil and (String.trim(rank) == "" or byte_size(rank) > 128) ->
        {:error, field: :rank, message: "must be nonblank and at most 128 bytes"}

      length(assignees) > 50 or not Enum.all?(assignees, &bounded_name?/1) ->
        {:error, field: :assignees, message: "must contain at most 50 bounded names"}

      length(labels) > 50 or not Enum.all?(labels, &bounded_name?/1) ->
        {:error, field: :labels, message: "must contain at most 50 bounded names"}

      map_size(fields) > 50 or not Enum.all?(Map.keys(fields), &bounded_name?/1) ->
        {:error, field: :custom_fields, message: "must contain at most 50 bounded names"}

      is_nil(board_id) and is_nil(column_id) ->
        :ok

      is_nil(board_id) or is_nil(column_id) ->
        {:error, field: :column_id, message: "board and column must be set together"}

      true ->
        validate_board_scope(board_id, column_id, workflow_id, state)
    end
  end

  defp validate_board_scope(board_id, column_id, workflow_id, state) do
    sql = """
    SELECT 1
    FROM board_columns AS bc
    JOIN boards AS board ON board.id = bc.board_id
    WHERE bc.id = $1::text::uuid
      AND board.id = $2::text::uuid
      AND board.workflow_id = $3::text::uuid
      AND bc.task_state = $4
    """

    # AUTHORIZATION: Ash change validation; the enclosing action carries the actor.
    case Ecto.Adapters.SQL.query!(SpruceGoose.Repo, sql, [
           column_id,
           board_id,
           workflow_id,
           to_string(state)
         ]).rows do
      [[1]] -> :ok
      _ -> {:error, field: :column_id, message: "does not match task workflow and state"}
    end
  end

  defp bounded_name?(value),
    do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= 128

  defp align_board_column(changeset, _state) when is_nil(changeset.data.board_id), do: changeset

  defp align_board_column(changeset, state) do
    sql = "SELECT id FROM board_columns WHERE board_id = $1::text::uuid AND task_state = $2"

    # AUTHORIZATION: Ash transition hook; the enclosing action carries the actor.
    case Ecto.Adapters.SQL.query!(SpruceGoose.Repo, sql, [
           changeset.data.board_id,
           to_string(state)
         ]).rows do
      [[column_id]] ->
        Ash.Changeset.change_attribute(changeset, :column_id, Ecto.UUID.load!(column_id))

      _ ->
        Ash.Changeset.add_error(changeset,
          field: :column_id,
          message: "has no column for target state"
        )
    end
  end

  defp completion_requirements(task) do
    with :ok <- diagnosis_evidence(task),
         {:ok, todos} <-
           Ash.read(Ash.Query.filter_input(SpruceGoose.Workflows.Todo, task_id: task.id)) do
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
