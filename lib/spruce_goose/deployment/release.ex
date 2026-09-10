defmodule SpruceGoose.Deployment.Release do
  @moduledoc """
  An accepted release: immutable source, pipeline, and typed artifact identity.

  Acceptance is an evidence judgement. The archive digest must already be held
  in custody by a succeeded `verify_artifact` derivation for a task in the same
  project, so a release cannot name bytes SpruceGoose has never verified. Image
  and file-collection digests are typed and validated in form; their custody
  lives outside this database and is not claimed here.
  """

  use Ash.Resource,
    domain: SpruceGoose.Deployment.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  require Ash.Query

  alias SpruceGoose.Checks.{HasRole, Readable}
  alias SpruceGoose.Deployment.ReleaseIdentity
  alias SpruceGoose.Derivations.OutcomeReceipt
  alias SpruceGoose.Workflows.Project

  postgres do
    table("deployment_releases")
    repo(SpruceGoose.Repo)
  end

  policies do
    policy action_type(:read), do: authorize_if(Readable)
    policy action(:accept), do: authorize_if(HasRole.operator())
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:release_id, :string, allow_nil?: false, public?: true)
    attribute(:forge_instance, :string, allow_nil?: false, public?: true)
    attribute(:repository, :string, allow_nil?: false, public?: true)
    attribute(:source_commit, :string, allow_nil?: false, public?: true)
    attribute(:pipeline_number, :integer, allow_nil?: false, public?: true)
    attribute(:pipeline_digest, :string, allow_nil?: false, public?: true)
    attribute(:artifacts, :map, allow_nil?: false, public?: true)
    attribute(:accepted_by, :string, allow_nil?: false, public?: true)
    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :project, Project do
      allow_nil?(false)
      attribute_writable?(true)
      public?(true)
    end
  end

  actions do
    defaults([:read])

    create :accept do
      accept([
        :project_id,
        :forge_instance,
        :repository,
        :source_commit,
        :pipeline_number,
        :pipeline_digest,
        :artifacts
      ])

      change(fn changeset, context ->
        case ReleaseIdentity.new(changeset.attributes) do
          {:ok, identity} ->
            {:ok, release_id} = ReleaseIdentity.id(identity)

            changeset
            |> Ash.Changeset.change_attribute(:release_id, release_id)
            |> Ash.Changeset.change_attribute(
              :artifacts,
              ReleaseIdentity.to_map(identity)["artifacts"]
            )
            |> Ash.Changeset.change_attribute(:accepted_by, actor_name(context.actor))

          {:error, reason} ->
            Ash.Changeset.add_error(changeset, field: :artifacts, message: inspect(reason))
        end
      end)

      validate(fn changeset, _context -> require_archive_custody(changeset) end)
    end
  end

  identities do
    identity(:stable_release_id, [:release_id])
  end

  @doc "The typed identity of an accepted release row."
  def identity(%{release_id: _} = release) do
    ReleaseIdentity.new(%{
      forge_instance: release.forge_instance,
      repository: release.repository,
      source_commit: release.source_commit,
      pipeline_number: release.pipeline_number,
      pipeline_digest: release.pipeline_digest,
      artifacts: release.artifacts
    })
  end

  defp actor_name(%{name: name}), do: name
  defp actor_name(_), do: nil

  # Custody is a fact this database can check, so it is checked. A release whose
  # archive nobody verified is not accepted, whatever its other fields say.
  defp require_archive_custody(changeset) do
    project_id = Ash.Changeset.get_attribute(changeset, :project_id)

    case Ash.Changeset.get_attribute(changeset, :artifacts) do
      %{"archive" => "sha256:" <> hex} when is_binary(project_id) ->
        # AUTHORIZATION: evidence lookup inside the actor-bound accept action; reads receipts only.
        OutcomeReceipt
        |> Ash.Query.filter(
          outcome == :succeeded and artifact_digest == ^hex and
            task.workflow.roadmap.project_id == ^project_id
        )
        |> Ash.exists?(authorize?: false)
        |> if(
          do: :ok,
          else:
            {:error,
             field: :artifacts,
             message: "archive digest has no succeeded verify_artifact receipt in this project"}
        )

      %{"archive" => _} ->
        {:error, field: :project_id, message: "is required"}

      _ ->
        :ok
    end
  end
end
