defmodule SpruceGoose.Workflows.CompletionClaim do
  @moduledoc """
  A checkable assertion attached to a task, probed against a declared target.

  Motivating failures (2026-08-24): `openclaw-secrets-vaultwarden-custody` was
  marked completed while the target host held no copy of the secret, and the
  Woodpecker retirement was marked completed while the unit was still
  `enabled`. In both cases the completion record asserted itself and nothing
  re-checked it.

  A claim pairs a probe with the target it runs against and the outcome that
  counts as success. Crucially, **declaring a claim does not execute it**: the
  data layer never shells out, so replay and projection stay deterministic.
  An external runner reads pending claims, executes them, and writes verdicts
  back through `record_verdict`.

  `target_key` binds by key rather than embedding a hostname, so re-pointing a
  target moves every claim with it.
  """
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}
  alias SpruceGoose.Workflows.{ClaimOutcome, ProbeExpectation}

  postgres do
    table("completion_claims")
    repo(SpruceGoose.Repo)

    references do
      reference(:task, on_delete: :delete, on_update: :update)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Readable)
    end

    policy action(:declare) do
      authorize_if(HasRole.operator())
    end

    # Returning a verdict is the verifier's job, distinct from declaring what
    # ought to be true.
    policy action(:record_verdict) do
      authorize_if(HasRole.operator())
      authorize_if(HasRole.artifact_verifier())
    end
  end

  attributes do
    uuid_primary_key(:id)

    # Bound by key, never by literal address, so the same claim survives a
    # redeployment onto different hardware.
    attribute(:target_key, :string, allow_nil?: false, public?: true)

    attribute(:probe, :string, allow_nil?: false, public?: true)
    attribute(:expectation, ProbeExpectation, allow_nil?: false, public?: true)

    attribute(:outcome, ClaimOutcome, allow_nil?: false, default: :unverified, public?: true)
    attribute(:detail, :string, public?: true)
    attribute(:verified_at, :utc_datetime_usec, public?: true)
    attribute(:verified_by, :string, public?: true)

    timestamps()
  end

  relationships do
    belongs_to :task, SpruceGoose.Workflows.Task do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :declare do
      primary?(true)
      accept([:task_id, :target_key, :probe, :expectation])
    end

    update :record_verdict do
      require_atomic?(false)
      accept([:outcome, :detail])

      change(fn changeset, context ->
        actor_name =
          case context.actor do
            %{name: name} -> name
            _ -> nil
          end

        changeset
        |> Ash.Changeset.force_change_attribute(:verified_at, DateTime.utc_now())
        |> Ash.Changeset.force_change_attribute(:verified_by, actor_name)
      end)
    end
  end
end
