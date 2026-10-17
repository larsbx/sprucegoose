defmodule SpruceGoose.Deployment.Artifact do
  @moduledoc """
  Typed content identity for deployment artifacts.

  Archive digests cover exact archive bytes; OCI image digests cover exact
  manifest or index bytes; file-collection v1 digests cover the native plane's
  deterministic ETF `{1, sorted_files}` encoding. None substitutes for another.
  This module verifies content only. It does not admit a release or fetch bytes.
  """

  @enforce_keys [:kind, :digest]
  defstruct @enforce_keys

  @kinds [:archive, :oci_image, :file_collection_v1]
  @digest ~r/\Asha256:[0-9a-f]{64}\z/

  def new(kind, digest) when kind in @kinds and is_binary(digest) do
    if Regex.match?(@digest, digest),
      do: {:ok, %__MODULE__{kind: kind, digest: digest}},
      else: {:error, :invalid_artifact_identity}
  end

  def new(_, _), do: {:error, :invalid_artifact_identity}

  def valid?(%__MODULE__{kind: kind, digest: digest} = artifact),
    do: new(kind, digest) == {:ok, artifact}

  def valid?(_), do: false

  @doc "Verify exact bytes with an independently declared expected artifact kind."
  def verify_bytes(%__MODULE__{kind: kind} = artifact, kind, bytes)
      when kind in [:archive, :oci_image] and is_binary(bytes) and byte_size(bytes) > 0 do
    if valid?(artifact) and artifact.digest == sha256(bytes),
      do: :ok,
      else: {:error, :artifact_digest_mismatch}
  end

  def verify_bytes(_, _, _), do: {:error, :invalid_artifact_verification}

  @doc "Encode a file collection using the original native plane's v1 identity."
  def from_files(files) when is_list(files) and files != [] do
    if Enum.all?(files, &valid_file?/1) and unique_paths?(files) do
      encoded = :erlang.term_to_binary({1, Enum.sort(files)}, [:deterministic])
      {:ok, artifact} = new(:file_collection_v1, sha256(encoded))
      {:ok, artifact, encoded}
    else
      {:error, :invalid_file_collection}
    end
  end

  def from_files(_), do: {:error, :invalid_file_collection}

  def verify_files(%__MODULE__{kind: :file_collection_v1} = artifact, files) do
    case from_files(files) do
      {:ok, ^artifact, _encoded} -> :ok
      {:ok, _, _} -> {:error, :artifact_digest_mismatch}
      error -> error
    end
  end

  def verify_files(_, _), do: {:error, :invalid_artifact_verification}

  defp valid_file?({path, bytes}) when is_binary(path) and is_binary(bytes) do
    path != "" and not String.contains?(path, <<0>>) and Path.type(path) == :relative and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp valid_file?(_), do: false
  defp unique_paths?(files), do: length(Enum.uniq_by(files, &elem(&1, 0))) == length(files)
  defp sha256(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
