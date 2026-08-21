defmodule SpruceGoose.Derivations.Permit do
  @moduledoc """
  A typed, single-use authorization to perform one bounded source derivation.

  The permit contains source identity and the permitted action. It never stores
  a shell command. Executors may only claim it and record one terminal outcome.
  """

  use Ash.Resource,
    domain: SpruceGoose.Derivations.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}
  alias SpruceGoose.Workflows.Task

  @actions [:test, :build_release, :verify_artifact]
  @states [:admitted, :claimed, :succeeded, :failed]
  @hex40 ~r/\A[0-9a-f]{40}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @repository ~r/\A[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+\z/
  @ref ~r/\Arefs\/(heads|tags)\/[A-Za-z0-9._\/-]+\z/

  postgres do
    table("derivation_permits")
    repo(SpruceGoose.Repo)

    check_constraints do
      check_constraint([:action, :input_artifact_digest], "typed_derivation_input",
        check:
          "(action = 'verify_artifact' AND input_artifact_digest ~ '^[0-9a-f]{64}$') OR " <>
            "(action <> 'verify_artifact' AND input_artifact_digest IS NULL)",
        message: "action input does not match the typed derivation"
      )
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Readable)
    end

    policy action(:admit) do
      authorize_if(HasRole.operator())
    end

    policy action([:claim, :succeed, :fail]) do
      authorize_if(HasRole.derivation_executor())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:permit_id, :string, allow_nil?: false, public?: true)
    attribute(:source_event_id, :string, allow_nil?: false, public?: true)
    attribute(:forge_instance, :string, allow_nil?: false, public?: true)
    attribute(:repository, :string, allow_nil?: false, public?: true)
    attribute(:commit_sha, :string, allow_nil?: false, public?: true)
    attribute(:tree_sha, :string, allow_nil?: false, public?: true)
    attribute(:ref, :string, allow_nil?: false, public?: true)
    attribute(:pipeline_digest, :string, allow_nil?: false, public?: true)
    attribute(:input_artifact_digest, :string, public?: true)

    attribute(:action, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: @actions]
    )

    attribute(:state, :atom,
      allow_nil?: false,
      public?: true,
      default: :admitted,
      constraints: [one_of: @states]
    )

    attribute(:executor_id, :string, public?: true)
    attribute(:evidence_digest, :string, public?: true)
    attribute(:artifact_digest, :string, public?: true)
    attribute(:failure_reason, :string, public?: true)
    attribute(:claimed_at, :utc_datetime_usec, public?: true)
    attribute(:completed_at, :utc_datetime_usec, public?: true)
    timestamps()
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

    create :admit do
      primary?(true)

      accept([
        :task_id,
        :source_event_id,
        :forge_instance,
        :repository,
        :commit_sha,
        :tree_sha,
        :ref,
        :pipeline_digest,
        :input_artifact_digest,
        :action
      ])

      validate(fn changeset, _context -> validate_source(changeset) end)
      validate(fn changeset, _context -> validate_action_input(changeset) end)
      validate(fn changeset, _context -> validate_task(changeset) end)

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(
          changeset,
          :permit_id,
          deterministic_id(changeset.attributes)
        )
      end)
    end

    update :claim do
      require_atomic?(false)
      accept([])
      argument(:executor_id, :string, allow_nil?: false)
      validate(fn changeset, _context -> require_state(changeset, :admitted) end)

      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(
          :executor_id,
          Ash.Changeset.get_argument(changeset, :executor_id)
        )
        |> Ash.Changeset.change_attribute(:state, :claimed)
        |> Ash.Changeset.change_attribute(:claimed_at, DateTime.utc_now())
      end)
    end

    update :succeed do
      require_atomic?(false)
      accept([])
      argument(:evidence_digest, :string, allow_nil?: false)
      argument(:artifact_digest, :string)
      validate(fn changeset, _context -> require_state(changeset, :claimed) end)
      validate(fn changeset, _context -> validate_success(changeset) end)

      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(
          :evidence_digest,
          Ash.Changeset.get_argument(changeset, :evidence_digest)
        )
        |> Ash.Changeset.change_attribute(
          :artifact_digest,
          Ash.Changeset.get_argument(changeset, :artifact_digest)
        )
        |> Ash.Changeset.change_attribute(:state, :succeeded)
        |> Ash.Changeset.change_attribute(:completed_at, DateTime.utc_now())
      end)
    end

    update :fail do
      require_atomic?(false)
      accept([])
      argument(:failure_reason, :string, allow_nil?: false)
      validate(fn changeset, _context -> require_state(changeset, :claimed) end)
      validate(fn changeset, _context -> non_blank_argument(changeset, :failure_reason) end)

      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(
          :failure_reason,
          Ash.Changeset.get_argument(changeset, :failure_reason)
        )
        |> Ash.Changeset.change_attribute(:state, :failed)
        |> Ash.Changeset.change_attribute(:completed_at, DateTime.utc_now())
      end)
    end
  end

  identities do
    identity(:stable_permit_id, [:permit_id])
    identity(:one_per_source_event, [:source_event_id])
  end

  @doc "The stable permit ID derived from the complete immutable request."
  def deterministic_id(attrs) do
    canonical =
      [
        value(attrs, :task_id),
        value(attrs, :source_event_id),
        value(attrs, :forge_instance),
        value(attrs, :repository),
        value(attrs, :commit_sha),
        value(attrs, :tree_sha),
        value(attrs, :ref),
        value(attrs, :pipeline_digest),
        value(attrs, :input_artifact_digest),
        value(attrs, :action)
      ]
      |> Enum.map_join("\n", &to_string/1)

    "drv-" <> (:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower))
  end

  defp validate_source(changeset) do
    validators = [
      {:source_event_id, &non_blank?/1},
      {:forge_instance, &non_blank?/1},
      {:repository, &Regex.match?(@repository, &1)},
      {:commit_sha, &Regex.match?(@hex40, &1)},
      {:tree_sha, &Regex.match?(@hex40, &1)},
      {:ref, &Regex.match?(@ref, &1)},
      {:pipeline_digest, &Regex.match?(@hex64, &1)}
    ]

    Enum.find_value(validators, :ok, fn {field, valid?} ->
      value = Ash.Changeset.get_attribute(changeset, field)

      if is_binary(value) and valid?.(value),
        do: false,
        else: {:error, field: field, message: "is invalid"}
    end)
  end

  defp validate_task(changeset) do
    case Ash.get(Task, Ash.Changeset.get_attribute(changeset, :task_id), authorize?: false) do
      {:ok, %{state: :in_progress}} ->
        :ok

      {:ok, %{state: state}} ->
        {:error, field: :task_id, message: "must be in_progress, got #{state}"}

      _ ->
        {:error, field: :task_id, message: "does not identify a governed task"}
    end
  end

  defp validate_action_input(changeset) do
    action = Ash.Changeset.get_attribute(changeset, :action)
    digest = Ash.Changeset.get_attribute(changeset, :input_artifact_digest)

    cond do
      action == :verify_artifact and not (is_binary(digest) and Regex.match?(@hex64, digest)) ->
        {:error, field: :input_artifact_digest, message: "is required for verify_artifact"}

      action != :verify_artifact and not is_nil(digest) ->
        {:error, field: :input_artifact_digest, message: "is only valid for verify_artifact"}

      true ->
        :ok
    end
  end

  defp require_state(changeset, expected) do
    if changeset.data.state == expected,
      do: :ok,
      else: {:error, field: :state, message: "must be #{expected}, got #{changeset.data.state}"}
  end

  defp validate_success(changeset) do
    evidence = Ash.Changeset.get_argument(changeset, :evidence_digest)
    artifact = Ash.Changeset.get_argument(changeset, :artifact_digest)

    cond do
      not (is_binary(evidence) and Regex.match?(@hex64, evidence)) ->
        {:error, field: :evidence_digest, message: "is invalid"}

      changeset.data.action == :build_release and
          not (is_binary(artifact) and Regex.match?(@hex64, artifact)) ->
        {:error, field: :artifact_digest, message: "is required for build_release"}

      not is_nil(artifact) and not (is_binary(artifact) and Regex.match?(@hex64, artifact)) ->
        {:error, field: :artifact_digest, message: "is invalid"}

      true ->
        :ok
    end
  end

  defp non_blank_argument(changeset, name) do
    if non_blank?(Ash.Changeset.get_argument(changeset, name)),
      do: :ok,
      else: {:error, field: name, message: "must not be blank"}
  end

  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""
  defp value(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))
end
