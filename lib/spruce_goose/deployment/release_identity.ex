defmodule SpruceGoose.Deployment.ReleaseIdentity do
  @moduledoc """
  Canonical immutable identity of one release: where it came from and what it is.

  A release binds the forge instance, canonical repository, exact source commit,
  the Woodpecker pipeline run that produced it, and its artifacts. Artifact
  digests are *typed*: an archive digest, a file-collection digest, and an image
  digest are different facts about different bytes and are never conflated.
  """

  alias SpruceGoose.Kernel.{Canonical, ContentID}

  @enforce_keys [
    :forge_instance,
    :repository,
    :source_commit,
    :pipeline_number,
    :pipeline_digest,
    :artifacts
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @artifact_kinds [:archive, :files, :image]
  @hex40 ~r/\A[0-9a-f]{40}\z/
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @digest ~r/\Asha256:[0-9a-f]{64}\z/
  @repository ~r/\A[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+\z/

  @doc "The closed set of artifact kinds a release may carry."
  def artifact_kinds, do: @artifact_kinds

  @doc "Build a release identity from attributes, refusing anything malformed or untyped."
  def new(attrs) when is_map(attrs) do
    with {:ok, forge} <- string(attrs, :forge_instance, &(&1 != "")),
         {:ok, repository} <- string(attrs, :repository, &Regex.match?(@repository, &1)),
         {:ok, commit} <- string(attrs, :source_commit, &Regex.match?(@hex40, &1)),
         {:ok, number} <- positive_integer(attrs, :pipeline_number),
         {:ok, pipeline_digest} <- string(attrs, :pipeline_digest, &Regex.match?(@hex64, &1)),
         {:ok, artifacts} <- artifacts(fetch(attrs, :artifacts)) do
      {:ok,
       %__MODULE__{
         forge_instance: forge,
         repository: repository,
         source_commit: commit,
         pipeline_number: number,
         pipeline_digest: pipeline_digest,
         artifacts: artifacts
       }}
    end
  end

  def new(_), do: {:error, :invalid_release_identity}

  @doc "Deterministic release ID: `rel-` plus the SHA-256 of the canonical identity."
  def id(%__MODULE__{} = release) do
    with {:ok, bytes} <- Canonical.encode(to_map(release)),
         {:ok, %ContentID{digest: digest}} <- ContentID.derive(:sha256, bytes) do
      {:ok, "rel-" <> digest}
    end
  end

  @doc "The identity as a JSON-shaped map with string keys, for events and receipts."
  def to_map(%__MODULE__{} = release) do
    %{
      "forge_instance" => release.forge_instance,
      "repository" => release.repository,
      "source_commit" => release.source_commit,
      "pipeline_number" => release.pipeline_number,
      "pipeline_digest" => release.pipeline_digest,
      "artifacts" =>
        Map.new(release.artifacts, fn {kind, digest} -> {Atom.to_string(kind), digest} end)
    }
  end

  @doc "The bare 64-hex of one typed digest, or `nil` when the release carries none of that kind."
  def artifact_hex(%__MODULE__{artifacts: artifacts}, kind) do
    case Map.get(artifacts, kind) do
      "sha256:" <> hex -> hex
      _ -> nil
    end
  end

  defp artifacts(map) when is_map(map) and map_size(map) > 0 do
    Enum.reduce_while(map, {:ok, %{}}, fn {kind, digest}, {:ok, acc} ->
      with {:ok, kind} <- artifact_kind(kind),
           true <- is_binary(digest) and Regex.match?(@digest, digest) do
        {:cont, {:ok, Map.put(acc, kind, digest)}}
      else
        _ -> {:halt, {:error, {:invalid_artifact, kind}}}
      end
    end)
  end

  defp artifacts(_), do: {:error, :artifacts_required}

  defp artifact_kind(kind) when kind in @artifact_kinds, do: {:ok, kind}

  defp artifact_kind(kind) when is_binary(kind),
    do: Enum.find_value(@artifact_kinds, :error, &if(Atom.to_string(&1) == kind, do: {:ok, &1}))

  defp artifact_kind(_), do: :error

  defp string(attrs, key, valid?) do
    case fetch(attrs, key) do
      value when is_binary(value) ->
        if valid?.(value), do: {:ok, value}, else: {:error, {:invalid_field, key}}

      _ ->
        {:error, {:invalid_field, key}}
    end
  end

  defp positive_integer(attrs, key) do
    case fetch(attrs, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_field, key}}
    end
  end

  defp fetch(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
end
