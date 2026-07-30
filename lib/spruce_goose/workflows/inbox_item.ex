defmodule SpruceGoose.Workflows.InboxItem do
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("inbox_items")
    repo(SpruceGoose.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:capture_id, :string, allow_nil?: false, public?: true)
    attribute(:body, :string, allow_nil?: false, public?: true)

    attribute(:state, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      constraints: [one_of: [:pending, :resolved, :dropped]]
    )

    attribute(:resolution_reason, :string, public?: true)
    attribute(:promoted_task_id, :string, public?: true)
    attribute(:resolved_at, :utc_datetime_usec, public?: true)

    timestamps()
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:capture_id, :body])
      upsert?(true)
      upsert_identity(:stable_capture)
      upsert_fields([])
    end

    update :resolve do
      require_atomic?(false)
      accept([:resolution_reason, :promoted_task_id])

      argument(:to_state, :atom,
        allow_nil?: false,
        constraints: [one_of: [:resolved, :dropped]]
      )

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :state) do
          :pending ->
            changeset
            |> Ash.Changeset.force_change_attribute(
              :state,
              Ash.Changeset.get_argument(changeset, :to_state)
            )
            |> Ash.Changeset.force_change_attribute(:resolved_at, DateTime.utc_now())

          state ->
            Ash.Changeset.add_error(changeset,
              field: :state,
              message: "capture is already #{state}"
            )
        end
      end)
    end
  end

  identities do
    identity(:stable_capture, [:capture_id])
  end

  validations do
    validate(string_length(:body, min: 1, max: 10_000))
  end
end
