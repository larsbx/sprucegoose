defmodule SpruceGoose.Blueprints.SourceVerifier do
  @moduledoc "Fetch and verify immutable blueprint source bytes."

  @callback verify(String.t(), String.t(), String.t()) ::
              {:ok, %{tree: String.t(), digest: String.t()}} | {:error, term()}

  def verify(repository, commit, path) do
    module =
      Application.get_env(
        :spruce_goose,
        :blueprint_source_verifier,
        SpruceGoose.Blueprints.ForgejoVerifier
      )

    module.verify(repository, commit, path)
  end
end
