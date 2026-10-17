defmodule SpruceGoose.Deployment.Operation do
  @moduledoc """
  One requested execution of an approved effect, with its stable identity and phase.

  `operation_id` is derived from the authorization it spends, so the same
  approval can never produce two operations and a retry always names the same
  operation on the host. Phases are `requested`, `started`, `completed`; the
  certified events on the deployment stream are the receipts for each, and
  `observation_count` records how many times host inspection was consulted.
  """

  use Ash.Resource,
    domain: SpruceGoose.Deployment.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}
  alias SpruceGoose.Deployment.{Projection, Record}

  @phases [:requested, :started, :completed]

  postgres do
    table("deployment_operations")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read), do: authorize_if(Readable)
    policy action(:request), do: authorize_if(HasRole.operator())
    policy action([:start, :complete, :observe]), do: authorize_if(HasRole.deployment_executor())
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:operation_id, :string, allow_nil?: false, public?: true)
    attribute(:authorization_id, :string, allow_nil?: false, public?: true)

    attribute(:action, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: Projection.operation_actions()]
    )

    attribute(:target_deployment_id, :string, public?: true)

    attribute(:phase, :atom,
      allow_nil?: false,
      default: :requested,
      public?: true,
      constraints: [one_of: @phases]
    )

    attribute(:outcome, :atom, public?: true, constraints: [one_of: [:succeeded, :failed]])
    attribute(:executor_id, :string, public?: true)
    attribute(:evidence_digest, :string, public?: true)
    attribute(:detail, :string, public?: true)
    attribute(:observation_count, :integer, allow_nil?: false, default: 0, public?: true)
    attribute(:started_at, :utc_datetime_usec, public?: true)
    attribute(:completed_at, :utc_datetime_usec, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :deployment, Record do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :request do
      accept([:deployment_id, :authorization_id, :action, :target_deployment_id])

      change(fn changeset, _context ->
        authorization_id = Ash.Changeset.get_attribute(changeset, :authorization_id)

        Ash.Changeset.change_attribute(
          changeset,
          :operation_id,
          deterministic_id(authorization_id)
        )
      end)
    end

    update :start do
      require_atomic?(false)
      accept([:executor_id])
      validate(fn changeset, _context -> require_phase(changeset, [:requested]) end)

      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(:phase, :started)
        |> Ash.Changeset.change_attribute(:started_at, DateTime.utc_now())
      end)
    end

    update :complete do
      require_atomic?(false)
      accept([:outcome, :evidence_digest, :detail])
      validate(fn changeset, _context -> require_phase(changeset, [:started]) end)
      validate(present(:outcome))

      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.change_attribute(:phase, :completed)
        |> Ash.Changeset.change_attribute(:completed_at, DateTime.utc_now())
      end)
    end

    update :observe do
      require_atomic?(false)
      accept([:detail])
      validate(fn changeset, _context -> require_phase(changeset, [:started, :completed]) end)

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(
          changeset,
          :observation_count,
          changeset.data.observation_count + 1
        )
      end)
    end
  end

  identities do
    identity(:stable_operation_id, [:operation_id])
    identity(:one_operation_per_authorization, [:authorization_id])
  end

  def phases, do: @phases

  @doc "The stable operation ID spent by one authorization."
  def deterministic_id(authorization_id) when is_binary(authorization_id),
    do: "dpo-" <> (:crypto.hash(:sha256, authorization_id) |> Base.encode16(case: :lower))

  defp require_phase(%{data: %{phase: phase}}, allowed) do
    if phase in allowed,
      do: :ok,
      else:
        {:error,
         field: :phase, message: "operation is #{phase}; expected #{Enum.join(allowed, " or ")}"}
  end
end
