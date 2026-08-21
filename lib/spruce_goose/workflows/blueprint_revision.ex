defmodule SpruceGoose.Workflows.BlueprintRevision do
  @moduledoc """
  An immutable pointer to one reviewed repository blueprint.

  Live workflow and task state remains in SpruceGoose. This record binds that
  authority to the exact Forgejo source revision an operator reviewed.
  """

  use Ash.Resource,
    domain: SpruceGoose.Workflows,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias SpruceGoose.Checks.{HasRole, Readable}

  @hex40 ~r/\A[0-9a-f]{40}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @repository ~r/\A[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+\z/
  @path ~r/\A(?!\/)(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9._\/-]+\z/

  postgres do
    table("workflow_blueprint_revisions")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if(Readable)
    end

    policy action(:register) do
      authorize_if(HasRole.approver())
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:revision_id, :string, allow_nil?: false, public?: true)
    attribute(:repository, :string, allow_nil?: false, public?: true)
    attribute(:source_commit, :string, allow_nil?: false, public?: true)
    attribute(:source_tree, :string, allow_nil?: false, public?: true)
    attribute(:source_path, :string, allow_nil?: false, public?: true)
    attribute(:manifest_digest, :string, allow_nil?: false, public?: true)
    attribute(:schema_version, :integer, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :project, SpruceGoose.Workflows.Project do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :register do
      primary?(true)

      accept([
        :project_id,
        :repository,
        :source_commit,
        :source_tree,
        :source_path,
        :manifest_digest,
        :schema_version
      ])

      validate(fn changeset, _context -> validate_source(changeset) end)

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(
          changeset,
          :revision_id,
          deterministic_id(changeset.attributes)
        )
      end)
    end
  end

  identities do
    identity(:stable_revision_id, [:revision_id])

    identity(
      :one_blueprint_per_source,
      [:project_id, :repository, :source_commit, :source_path]
    )
  end

  @doc "Derive the stable revision ID from the complete source identity."
  def deterministic_id(attrs) do
    canonical =
      [
        value(attrs, :project_id),
        value(attrs, :repository),
        value(attrs, :source_commit),
        value(attrs, :source_tree),
        value(attrs, :source_path),
        value(attrs, :manifest_digest),
        value(attrs, :schema_version)
      ]
      |> Enum.map_join("\n", &to_string/1)

    "bpr-" <> (:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower))
  end

  defp validate_source(changeset) do
    validators = [
      {:repository, &Regex.match?(@repository, &1)},
      {:source_commit, &Regex.match?(@hex40, &1)},
      {:source_tree, &Regex.match?(@hex40, &1)},
      {:source_path, &Regex.match?(@path, &1)},
      {:manifest_digest, &Regex.match?(@hex64, &1)}
    ]

    Enum.find_value(validators, validate_schema(changeset), fn {field, valid?} ->
      input = Ash.Changeset.get_attribute(changeset, field)

      if is_binary(input) and valid?.(input),
        do: false,
        else: {:error, field: field, message: "is invalid"}
    end)
  end

  defp validate_schema(changeset) do
    if Ash.Changeset.get_attribute(changeset, :schema_version) == 1,
      do: :ok,
      else: {:error, field: :schema_version, message: "must be 1"}
  end

  defp value(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, to_string(key))
end
