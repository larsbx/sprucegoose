defmodule SpruceGoose.Actors.Actor do
  @moduledoc """
  A named party that may act: a human, or one of the fleet's agents.

  Deliberately carries no credential. On this host every agent runs as the same
  unix user, so a name here is a *declaration* rather than proof — see
  `SpruceGoose.Actors.Resolver` for the boundary and the seam that would move
  it.
  """

  use Ash.Resource,
    domain: SpruceGoose.Actors,
    data_layer: AshPostgres.DataLayer

  alias SpruceGoose.Actors.ActorKind

  postgres do
    table("actors")
    repo(SpruceGoose.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:kind, ActorKind, allow_nil?: false, public?: true)
    attribute(:description, :string, public?: true)
    attribute(:disabled_at, :utc_datetime_usec, public?: true)
    attribute(:disabled_reason, :string, public?: true)
    attribute(:created_by, :string, allow_nil?: false, public?: true)
    attribute(:lock_version, :integer, allow_nil?: false, default: 1, public?: true)
    timestamps()
  end

  relationships do
    has_many(:grants, SpruceGoose.Actors.Grant)
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:name, :kind, :description, :created_by])
    end

    update :disable do
      require_atomic?(false)
      accept([:disabled_reason])

      validate(fn changeset, _context ->
        if is_nil(changeset.data.disabled_at),
          do: :ok,
          else: {:error, field: :disabled_at, message: "actor is already disabled"}
      end)

      change(set_attribute(:disabled_at, &DateTime.utc_now/0))
      change(optimistic_lock(:lock_version))
    end

    update :enable do
      require_atomic?(false)
      accept([])
      change(set_attribute(:disabled_at, nil))
      change(set_attribute(:disabled_reason, nil))
      change(optimistic_lock(:lock_version))
    end

    destroy :destroy do
      primary?(true)
    end
  end

  identities do
    identity(:unique_actor_name, [:name])
  end

  validations do
    # Bounded and shell-safe: an actor name lands in audit records and error
    # messages, and is typed by hand into every `--as`.
    validate(match(:name, ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/),
      message: "must be lowercase alphanumeric with . _ -, at most 64 characters"
    )

    validate(string_length(:description, max: 512))
    validate(string_length(:disabled_reason, min: 1, max: 512), on: [:update])
  end

  # Matched structurally rather than on `%__MODULE__{}`: Ash builds the struct in
  # a before_compile hook, so it does not exist yet inside this module body.
  def active?(%{disabled_at: nil}), do: true
  def active?(_actor), do: false
end
