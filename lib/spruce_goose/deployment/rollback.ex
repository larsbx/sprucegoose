defmodule SpruceGoose.Deployment.Rollback do
  @moduledoc "Pure rollback target validation; records no completion or authorization."

  alias SpruceGoose.Deployment.Release

  def validate(
        %{
          deployment_id: id,
          project: project,
          environment: environment,
          state: state,
          release: %Release{} = release
        },
        %{
          deployment_id: target_id,
          project: project,
          environment: environment,
          state: :ready,
          release: %Release{} = target_release
        }
      )
      when state in [:ready, :failed, :deploying, :verifying] do
    if present?(id) and present?(target_id) and present?(project) and present?(environment) and
         id != target_id and release != target_release and valid_release?(release) and
         valid_release?(target_release),
       do: :ok,
       else: {:error, :invalid_rollback_target}
  end

  def validate(_, _), do: {:error, :invalid_rollback_target}

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp valid_release?(release),
    do: Release.new(release.source_commit, release.image_digest) == {:ok, release}
end
