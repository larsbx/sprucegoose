defmodule SpruceGoose.Kernel.ArtifactStore do
  @moduledoc "Port for immutable content-addressed artifact storage."

  alias SpruceGoose.Kernel.ContentID

  @type receipt :: %{adapter_id: String.t(), content_id: ContentID.t()}

  @callback get(term(), ContentID.t()) :: {:ok, binary()} | {:error, atom()}
  @callback verify(term(), receipt()) :: :ok | {:error, atom()}
end
