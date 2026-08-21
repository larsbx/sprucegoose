defmodule SpruceGoose.Actors.Grant do
  @moduledoc """
  One role held by one actor over one scope.

  A separate resource rather than an array column on `Actor`, because the
  questions actually asked of a permission are "who granted this, and when" and
  "revoke exactly this one" — neither of which an array answers well.

  `scope` is `*` (fleet-wide) or `project:KEY`. Two levels only: deeper scoping
  turns every permission check into a tree walk, and work on this fleet is
  partitioned by project.
  """

  use Ash.Resource,
    domain: SpruceGoose.Actors,
    data_layer: AshPostgres.DataLayer

  alias SpruceGoose.Actors.Role

  @global "*"

  postgres do
    table("actor_grants")
    repo(SpruceGoose.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:role, Role, allow_nil?: false, public?: true)
    attribute(:scope, :string, allow_nil?: false, public?: true)
    attribute(:granted_by, :string, allow_nil?: false, public?: true)
    attribute(:granted_at, :utc_datetime_usec, allow_nil?: false, public?: true)
    timestamps()
  end

  relationships do
    belongs_to :actor, SpruceGoose.Actors.Actor do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :create do
      primary?(true)
      accept([:actor_id, :role, :scope, :granted_by])
      change(set_attribute(:granted_at, &DateTime.utc_now/0))
    end

    destroy :destroy do
      primary?(true)
    end
  end

  identities do
    identity(:unique_grant, [:actor_id, :role, :scope])
  end

  validations do
    validate(fn changeset, _context ->
      changeset |> Ash.Changeset.get_attribute(:scope) |> valid_scope()
    end)
  end

  def global, do: @global

  @doc "Parse a scope string. Existence of the named project is checked at grant time."
  def parse_scope(@global), do: {:ok, :global}

  def parse_scope("project:" <> key) when byte_size(key) > 0, do: {:ok, {:project, key}}

  def parse_scope(_scope), do: {:error, "scope must be #{@global} or project:KEY"}

  defp valid_scope(scope) do
    case parse_scope(scope) do
      {:ok, _parsed} -> :ok
      {:error, message} -> {:error, field: :scope, message: message}
    end
  end
end
