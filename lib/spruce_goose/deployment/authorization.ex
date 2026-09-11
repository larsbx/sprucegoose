defmodule SpruceGoose.Deployment.Authorization do
  @moduledoc """
  A single-use, expiring approval to execute exactly one effect on one deployment.

  Issued only by a human holding `approver` over the deployment's project. The
  row is immutable; it is spent by the one `Operation` row that references it,
  and PostgreSQL's uniqueness on that reference makes single use an invariant
  rather than a convention. Presence of an authorization is never sufficient:
  the operation request re-validates every precondition against live state.
  """

  use Ash.Resource,
    domain: SpruceGoose.Deployment.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Actors.Actor
  alias SpruceGoose.Checks.{HasRole, Readable}
  alias SpruceGoose.Deployment.{Projection, Record}

  @default_ttl_seconds 900
  @max_ttl_seconds 3_600

  postgres do
    table("deployment_authorizations")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read), do: authorize_if(Readable)
    policy action(:issue), do: authorize_if(HasRole.approver())
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:authorization_id, :string, allow_nil?: false, public?: true)

    attribute(:action, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: Projection.operation_actions()]
    )

    attribute(:target_deployment_id, :string, public?: true)
    attribute(:approved_by, :string, allow_nil?: false, public?: true)
    attribute(:approval_reference, :string, allow_nil?: false, public?: true)
    attribute(:issued_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false, public?: true)
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

    create :issue do
      accept([:deployment_id, :action, :target_deployment_id, :approval_reference])
      argument(:ttl_seconds, :integer, default: @default_ttl_seconds)

      validate(fn changeset, context -> require_human_approver(context.actor) end)
      validate(fn changeset, _context -> validate_ttl(changeset) end)
      validate(fn changeset, _context -> validate_reference(changeset) end)
      validate(fn changeset, _context -> validate_target(changeset) end)

      change(fn changeset, context ->
        now = DateTime.utc_now()
        ttl = Ash.Changeset.get_argument(changeset, :ttl_seconds)

        changeset
        |> Ash.Changeset.change_attribute(
          :authorization_id,
          SpruceGoose.PrefixedId.generate("dpa")
        )
        |> Ash.Changeset.change_attribute(:approved_by, context.actor.name)
        |> Ash.Changeset.change_attribute(:issued_at, now)
        |> Ash.Changeset.change_attribute(:expires_at, DateTime.add(now, ttl, :second))
      end)
    end
  end

  identities do
    identity(:stable_authorization_id, [:authorization_id])
  end

  def default_ttl_seconds, do: @default_ttl_seconds
  def max_ttl_seconds, do: @max_ttl_seconds

  @doc "Is the authorization still within its validity window at `now`?"
  def unexpired?(%{expires_at: expires_at}, now \\ DateTime.utc_now()),
    do: DateTime.compare(now, expires_at) == :lt

  # Approval is a recorded human decision. An agent or system actor holding
  # approver may approve revisions; it may not license an effect on a host.
  defp require_human_approver(%Actor{kind: :human}), do: :ok

  defp require_human_approver(_actor),
    do: {:error, field: :approved_by, message: "must be a human actor"}

  # Longer requests are refused, not clamped.
  defp validate_ttl(changeset) do
    case Ash.Changeset.get_argument(changeset, :ttl_seconds) do
      ttl when is_integer(ttl) and ttl > 0 and ttl <= @max_ttl_seconds ->
        :ok

      ttl when is_integer(ttl) and ttl > @max_ttl_seconds ->
        {:error, field: :ttl_seconds, message: "exceeds #{@max_ttl_seconds} seconds"}

      _ ->
        {:error, field: :ttl_seconds, message: "must be a positive integer"}
    end
  end

  defp validate_reference(changeset) do
    case Ash.Changeset.get_attribute(changeset, :approval_reference) do
      reference when is_binary(reference) and reference != "" -> :ok
      _ -> {:error, field: :approval_reference, message: "is required"}
    end
  end

  # A rollback authorization names the target it approves; nothing else may.
  defp validate_target(changeset) do
    action = Ash.Changeset.get_attribute(changeset, :action)
    target = Ash.Changeset.get_attribute(changeset, :target_deployment_id)

    cond do
      action == :execute_rollback and not (is_binary(target) and target != "") ->
        {:error, field: :target_deployment_id, message: "is required for execute_rollback"}

      action != :execute_rollback and not is_nil(target) ->
        {:error, field: :target_deployment_id, message: "is only valid for execute_rollback"}

      true ->
        :ok
    end
  end
end
