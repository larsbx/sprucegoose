defmodule SpruceGoose.Workflows.InboxItem do
  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}

  postgres do
    table("inbox_items")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(Readable)
    end

    # Captures arrive before triage, so they belong to no project yet and
    # resolve to global scope. Working the inbox therefore needs a fleet-wide
    # operator grant, not a project-scoped one.
    policy action_type([:create, :update, :destroy]) do
      authorize_if(HasRole.operator())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:capture_id, :string, allow_nil?: false, public?: true)
    attribute(:body, :string, allow_nil?: false, public?: true)

    attribute(:request_type, :atom,
      public?: true,
      constraints: [one_of: [:task, :diagnosis, :roadmap, :workflow, :project]]
    )

    attribute(:priority, :integer, public?: true, constraints: [min: 0, max: 5])
    attribute(:title, :string, public?: true)
    attribute(:definition_of_done, :string, public?: true)
    attribute(:proposed_project, :string, public?: true)
    attribute(:proposed_roadmap, :string, public?: true)
    attribute(:proposed_workflow, :string, public?: true)
    attribute(:classified_at, :utc_datetime_usec, public?: true)

    attribute(:state, :atom,
      allow_nil?: false,
      default: :pending,
      public?: true,
      constraints: [one_of: [:pending, :classified, :resolved, :dropped]]
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

    create :submit do
      accept([:capture_id, :body, :request_type, :priority, :title, :definition_of_done])

      validate(present([:request_type, :priority, :title, :definition_of_done]))
    end

    update :classify do
      require_atomic?(false)
      accept([:proposed_project, :proposed_roadmap, :proposed_workflow])

      change(fn changeset, _context ->
        case Ash.Changeset.get_data(changeset, :state) do
          state when state in [:pending, :classified] ->
            changeset
            |> Ash.Changeset.force_change_attribute(:state, :classified)
            |> Ash.Changeset.force_change_attribute(:classified_at, DateTime.utc_now())

          state ->
            Ash.Changeset.add_error(changeset,
              field: :state,
              message: "capture is already #{state}"
            )
        end
      end)
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
    validate(string_length(:title, min: 1, max: 500), where: present(:title))

    validate(string_length(:definition_of_done, min: 1, max: 2_000),
      where: present(:definition_of_done)
    )

    validate(string_length(:proposed_project, min: 1, max: 255),
      where: present(:proposed_project)
    )

    validate(string_length(:proposed_roadmap, min: 1, max: 255),
      where: present(:proposed_roadmap)
    )

    validate(string_length(:proposed_workflow, min: 1, max: 255),
      where: present(:proposed_workflow)
    )
  end
end
