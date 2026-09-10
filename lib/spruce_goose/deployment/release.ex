defmodule SpruceGoose.Deployment.Release do
  @moduledoc "Legacy immutable source and OCI image identity, retained for import compatibility."

  @enforce_keys [:source_commit, :image_digest]
  defstruct [:source_commit, :image_digest]

  @type t :: %__MODULE__{
          source_commit: binary(),
          image_digest: binary()
        }

  def new(source_commit, "sha256:" <> digest = image_digest)
      when byte_size(source_commit) == 40 and byte_size(digest) == 64 do
    if lowercase_hex?(source_commit) and lowercase_hex?(digest) do
      {:ok, %__MODULE__{source_commit: source_commit, image_digest: image_digest}}
    else
      {:error, :invalid_release_identity}
    end
  end

  def new(_, _), do: {:error, :invalid_release_identity}

  defp lowercase_hex?(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?f))
  end
end
