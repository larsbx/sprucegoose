defmodule SpruceGoose.Deployment.BuildManifest do
  @moduledoc """
  Canonical, content-addressed inputs for a reproducible build.

  The manifest contains no ambient host state. Callers must declare the exact
  source commit, builder image, commands, environment, and input digests.
  """

  @version 1
  @enforce_keys [
    :source_commit,
    :builder_image_digest,
    :commands,
    :environment,
    :inputs,
    :encoded,
    :digest
  ]
  defstruct @enforce_keys

  def new(source_commit, builder_image_digest, commands, environment, inputs)
      when is_list(commands) and is_map(environment) and is_list(inputs) do
    with :ok <- validate_commit(source_commit),
         :ok <- validate_digest(builder_image_digest),
         {:ok, commands} <- normalize_commands(commands),
         {:ok, environment} <- normalize_environment(environment),
         {:ok, inputs} <- normalize_inputs(inputs) do
      encoded =
        :erlang.term_to_binary(
          {@version, source_commit, builder_image_digest, commands, environment, inputs},
          [:deterministic]
        )

      {:ok,
       %__MODULE__{
         source_commit: source_commit,
         builder_image_digest: builder_image_digest,
         commands: commands,
         environment: environment,
         inputs: inputs,
         encoded: encoded,
         digest: sha256(encoded)
       }}
    end
  end

  def new(_, _, _, _, _), do: {:error, :invalid_build_manifest}

  def valid?(%__MODULE__{} = manifest) do
    with {:ok, canonical} <-
           new(
             manifest.source_commit,
             manifest.builder_image_digest,
             manifest.commands,
             Map.new(manifest.environment),
             manifest.inputs
           ) do
      manifest == canonical
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def valid?(_), do: false

  defp normalize_commands(commands) do
    if commands != [] and Enum.all?(commands, &present?/1),
      do: {:ok, commands},
      else: {:error, :invalid_build_manifest}
  end

  defp normalize_environment(environment) do
    entries = Enum.sort(environment)

    if Enum.all?(entries, fn {key, value} -> present?(key) and is_binary(value) end),
      do: {:ok, entries},
      else: {:error, :invalid_build_manifest}
  end

  defp normalize_inputs(inputs) do
    with true <- inputs != [], true <- Enum.all?(inputs, &valid_input?/1) do
      normalized = Enum.sort(inputs)

      if normalized |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == length(normalized),
        do: {:ok, normalized},
        else: {:error, :invalid_build_manifest}
    else
      _ -> {:error, :invalid_build_manifest}
    end
  end

  defp valid_input?({path, digest}), do: valid_path?(path) and valid_digest?(digest)
  defp valid_input?(_), do: false

  defp validate_commit(commit) when is_binary(commit) and byte_size(commit) == 40 do
    if lowercase_hex?(commit), do: :ok, else: {:error, :invalid_build_manifest}
  end

  defp validate_commit(_), do: {:error, :invalid_build_manifest}

  defp validate_digest(digest),
    do: if(valid_digest?(digest), do: :ok, else: {:error, :invalid_build_manifest})

  defp valid_digest?("sha256:" <> digest), do: byte_size(digest) == 64 and lowercase_hex?(digest)
  defp valid_digest?(_), do: false

  defp valid_path?(path) when is_binary(path) do
    present?(path) and Path.type(path) == :relative and
      Path.split(path) |> Enum.all?(&(&1 not in [".", ".."]))
  end

  defp valid_path?(_), do: false
  defp present?(value), do: is_binary(value) and value != ""

  defp lowercase_hex?(value),
    do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 in ?0..?9 or &1 in ?a..?f))

  defp sha256(bytes), do: "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
