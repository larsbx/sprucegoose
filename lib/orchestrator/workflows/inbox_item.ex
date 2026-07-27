defmodule Orchestrator.Workflows.InboxItem do
  use Ash.Resource,
    domain: Orchestrator.Workflows,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("inbox_items")
    repo(Orchestrator.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:capture_id, :string, allow_nil?: false, public?: true)
    attribute(:body, :string, allow_nil?: false, public?: true)

    attribute(:state, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending]]
    )

    timestamps()
  end

  identities do
    identity(:stable_capture, [:capture_id])
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
  end

  validations do
    validate(string_length(:body, min: 1, max: 10_000))
  end
end
