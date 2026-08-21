defmodule SpruceGoose.Kernel.ContentID do
  @moduledoc "Immutable identity derived from exact bytes and a named digest algorithm."

  @enforce_keys [:algorithm, :digest]
  defstruct [:algorithm, :digest]

  @type t :: %__MODULE__{algorithm: :sha256, digest: String.t()}

  @spec derive(atom(), binary()) :: {:ok, t()} | {:error, atom()}
  def derive(:sha256, bytes) when is_binary(bytes) do
    {:ok,
     %__MODULE__{
       algorithm: :sha256,
       digest: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
     }}
  end

  def derive(_algorithm, _bytes), do: {:error, :unsupported_algorithm}

  @spec verify(t(), binary()) :: :ok | {:error, atom()}
  def verify(%__MODULE__{algorithm: :sha256} = expected, bytes) when is_binary(bytes) do
    case derive(:sha256, bytes) do
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, :content_mismatch}
    end
  end

  def verify(%__MODULE__{}, _bytes), do: {:error, :unsupported_algorithm}
  def verify(_identity, _bytes), do: {:error, :invalid_content_identity}
end
