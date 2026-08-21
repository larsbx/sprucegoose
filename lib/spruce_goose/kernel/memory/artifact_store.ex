defmodule SpruceGoose.Kernel.Memory.ArtifactStore do
  @moduledoc "Reference in-memory ArtifactStore adapter for kernel proofs."

  @behaviour SpruceGoose.Kernel.ArtifactStore

  alias SpruceGoose.Kernel.ContentID

  @enforce_keys [:adapter_id, :artifacts]
  defstruct [:adapter_id, :artifacts]

  def new(adapter_id) when is_binary(adapter_id) and adapter_id != "",
    do: %__MODULE__{adapter_id: adapter_id, artifacts: %{}}

  def put(%__MODULE__{} = store, bytes) when is_binary(bytes) do
    with {:ok, content_id} <- ContentID.derive(:sha256, bytes) do
      receipt = %{adapter_id: store.adapter_id, content_id: content_id}
      {:ok, receipt, %{store | artifacts: Map.put(store.artifacts, content_id, bytes)}}
    end
  end

  @impl true
  def get(%__MODULE__{} = store, %ContentID{} = content_id) do
    case Map.fetch(store.artifacts, content_id) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :not_found}
    end
  end

  @impl true
  def verify(%__MODULE__{adapter_id: adapter_id}, %{adapter_id: receipt_adapter})
      when adapter_id != receipt_adapter,
      do: {:error, :wrong_adapter}

  def verify(%__MODULE__{} = store, %{content_id: %ContentID{} = content_id}) do
    with {:ok, bytes} <- get(store, content_id) do
      ContentID.verify(content_id, bytes)
    end
  end

  def verify(_store, _receipt), do: {:error, :invalid_receipt}
end
