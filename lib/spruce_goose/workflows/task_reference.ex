defmodule SpruceGoose.Workflows.TaskReference do
  @moduledoc """
  A single timestamped piece of evidence attached to a task.

  Evidence previously lived as anonymous maps inside `Task.input`, which
  recorded *what* was claimed but never *when* it arrived. That made "the
  newest evidence on this task is older than N" unanswerable, so an absent
  write was indistinguishable from a task with nothing new to record.

  Two properties matter here:

  * `recorded_at` is set by the resource, not supplied by the caller, so a
    writer cannot backdate or postdate its own evidence.
  * `backfilled` marks rows migrated out of `Task.input`. Those rows have a
    `nil` `recorded_at` because their true recording time was never captured.
    They are deliberately *not* given a synthetic timestamp, and freshness
    queries must never count them as genuine.

  References are immutable: there is no update action. Evidence that can be
  edited after the fact is not evidence.
  """
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}
  alias SpruceGoose.Workflows.ReferenceKind

  postgres do
    table("task_references")
    repo(SpruceGoose.Repo)

    references do
      reference(:task, on_delete: :delete, on_update: :update)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Readable)
    end

    # Recording evidence is part of driving work, so it sits with the operator
    # alongside the task transitions it accompanies.
    policy action(:record) do
      authorize_if(HasRole.operator())
      authorize_if(HasRole.author())
    end

    # Backfill is a migration mechanism, not an operator affordance: it is the
    # only way to create a reference whose recording time is unknown.
    policy action(:backfill) do
      authorize_if(HasRole.approver())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:kind, ReferenceKind, allow_nil?: false, public?: true)
    attribute(:value, :string, allow_nil?: false, public?: true)

    # Nil only for backfilled rows, whose true recording time is unknown.
    attribute(:recorded_at, :utc_datetime_usec, public?: true)
    attribute(:recorded_by, :string, public?: true)

    attribute(:backfilled, :boolean, allow_nil?: false, default: false, public?: true)

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

    create :record do
      primary?(true)
      accept([:task_id, :kind, :value])

      change(fn changeset, context ->
        actor_name =
          case context.actor do
            %{name: name} -> name
            _ -> nil
          end

        changeset
        |> Ash.Changeset.force_change_attribute(:recorded_at, DateTime.utc_now())
        |> Ash.Changeset.force_change_attribute(:recorded_by, actor_name)
        |> Ash.Changeset.force_change_attribute(:backfilled, false)
      end)
    end

    # Migration-only path for references rescued from `Task.input`. It records
    # that the evidence existed without inventing when it was written.
    create :backfill do
      accept([:task_id, :kind, :value])

      change(fn changeset, _context ->
        changeset
        |> Ash.Changeset.force_change_attribute(:recorded_at, nil)
        |> Ash.Changeset.force_change_attribute(:recorded_by, nil)
        |> Ash.Changeset.force_change_attribute(:backfilled, true)
      end)
    end
  end
end
