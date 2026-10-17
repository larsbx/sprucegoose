defmodule SpruceGoose.ReleaseValidator do
  @moduledoc "Boot-free, read-only governed archive inspection and pre-mutation validation."

  alias SpruceGoose.ReleaseProvenance, as: Provenance
  @member ~r"\Areleases/(?!\.{1,2}(?:/|$))[^/]+/governed-provenance\.json\z"
  @inventory_schema "spruce-goose-migration-inventory-v1"

  def inspect_archive(path) when is_binary(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, tar_bytes} <- archive_payload(path, bytes),
         do: inspect_archive_bytes(tar_bytes)
  end

  def inspect_archive_bytes(bytes) when is_binary(bytes) do
    with {:ok, entries} <- archive_entries(bytes),
         provenance_entries =
           Enum.filter(entries, fn {name, _} ->
             Path.basename(name) == "governed-provenance.json"
           end),
         :ok <- canonical_provenance_members(provenance_entries),
         [{member, provenance_bytes}] <- provenance_entries,
         {:ok, provenance} <- Provenance.decode_provenance(provenance_bytes) do
      {:ok, %{member: member, provenance_bytes: provenance_bytes, provenance: provenance}}
    else
      [] -> {:error, "archive contains no governed provenance member"}
      [_, _ | _] -> {:error, "archive contains multiple governed provenance members"}
      {:error, _} = error -> error
      _ -> {:error, "invalid governed archive"}
    end
  end

  def validate(opts) when is_list(opts) do
    archive = Keyword.fetch!(opts, :archive)
    receipt = Keyword.fetch!(opts, :receipt)
    expected_commit = Keyword.fetch!(opts, :expected_commit)
    expected_tree = Keyword.fetch!(opts, :expected_tree)
    artifact_only = Keyword.get(opts, :artifact_only, false)
    destination_inventory = Keyword.get(opts, :destination_inventory)

    with :ok <- inventory_mode(destination_inventory, artifact_only),
         {:ok, receipt_bytes} <- File.read(receipt),
         {:ok, receipt_value} <- Provenance.decode_receipt(receipt_bytes),
         :ok <-
           equal(Path.basename(archive), receipt_value["archive"]["filename"], "archive filename"),
         {:ok, archive_bytes} <- File.read(archive),
         :ok <-
           equal(
             Provenance.sha256(archive_bytes),
             receipt_value["archive"]["sha256"],
             "archive sha256"
           ),
         :ok <-
           equal(byte_size(archive_bytes), receipt_value["archive"]["size_bytes"], "archive size"),
         {:ok, tar_bytes} <- archive_payload(archive, archive_bytes),
         {:ok, inspected} <- inspect_archive_bytes(tar_bytes),
         :ok <-
           equal(
             Provenance.sha256(inspected.provenance_bytes),
             receipt_value["provenance_sha256"],
             "provenance sha256"
           ),
         :ok <- dirty_policy(inspected.provenance, Keyword.get(opts, :allow_dirty, false)),
         :ok <- equal(inspected.provenance["source"]["commit"], expected_commit, "source commit"),
         :ok <- equal(inspected.provenance["source"]["tree"], expected_tree, "source tree"),
         :ok <-
           equal(
             inspected.provenance["source"]["commit"],
             receipt_value["source"]["commit"],
             "receipt source commit"
           ),
         :ok <-
           equal(
             inspected.provenance["source"]["tree"],
             receipt_value["source"]["tree"],
             "receipt source tree"
           ),
         :ok <-
           equal(
             inspected.provenance["toolchain"]["erlang"],
             receipt_value["otp_version"],
             "receipt OTP version"
           ),
         :ok <-
           equal(
             inspected.provenance["toolchain"]["elixir"],
             receipt_value["elixir_version"],
             "receipt Elixir version"
           ),
         :ok <-
           equal(
             inspected.provenance["migration_set_sha256"],
             receipt_value["migration_set_sha256"],
             "receipt migration set"
           ),
         :ok <-
           equal(
             inspected.provenance["build"]["time_utc"],
             receipt_value["build_time_utc"],
             "receipt build time"
           ),
         {:ok, mode} <-
           validate_inventory(
             destination_inventory,
             artifact_only,
             inspected.provenance["migrations"]
           ) do
      {:ok,
       %{
         classification: classification(inspected.provenance),
         mode: mode,
         provenance: inspected.provenance,
         member: inspected.member
       }}
    end
  end

  def decode_inventory(bytes) do
    with {:ok, value} <- decode_json(bytes),
         :ok <- exact_keys(value, ["migrations", "schema"]),
         :ok <- equal(value["schema"], @inventory_schema, "inventory schema"),
         migrations when is_list(migrations) <- value["migrations"],
         :ok <- validate_migrations(migrations),
         canonical =
           "{\"migrations\":[" <>
             Enum.map_join(migrations, ",", &migration_json/1) <>
             "],\"schema\":\"#{@inventory_schema}\"}\n",
         :ok <- equal(bytes, canonical, "canonical inventory") do
      {:ok, migrations}
    else
      {:error, _} = error -> error
      _ -> {:error, "invalid migration inventory"}
    end
  end

  defp canonical_provenance_members([]), do: :ok

  defp canonical_provenance_members(entries) do
    names = Enum.map(entries, &elem(&1, 0))

    cond do
      Enum.any?(names, &(not Regex.match?(@member, &1))) ->
        {:error, "archive contains noncanonical governed provenance member"}

      length(names) > 1 ->
        {:error, "archive contains multiple governed provenance members"}

      true ->
        :ok
    end
  end

  defp archive_entries(bytes) do
    result =
      case :erl_tar.extract({:binary, bytes}, [:compressed, :memory]) do
        {:error, _} -> :erl_tar.extract({:binary, bytes}, [:memory])
        result -> result
      end

    case result do
      {:ok, files} ->
        entries =
          Enum.map(files, fn {name, content} ->
            {List.to_string(name), IO.iodata_to_binary(content)}
          end)

        names = Enum.map(entries, &elem(&1, 0))

        if length(names) == length(Enum.uniq(names)),
          do: {:ok, entries},
          else: {:error, "archive contains duplicate member names"}

      {:error, reason} ->
        {:error, "invalid archive: #{inspect(reason)}"}
    end
  end

  # This is the tool an operator runs against an archive *before* trusting it,
  # so the decompressed size is an attacker-chosen quantity. `System.cmd/3`
  # buffers the whole stream, and the tar members are buffered again after it: a
  # small crafted .tar.xz would exhaust memory in the one place that exists to
  # catch a bad archive.
  #
  # `--memlimit-decompress` bounds what xz itself will allocate; the byte
  # ceiling bounds what we accept from it. Both are needed — a low-memory
  # dictionary can still decompress to an unbounded stream.
  @max_decompressed_bytes 512 * 1024 * 1024
  @xz_memlimit "256MiB"

  defp archive_payload(path, bytes) do
    if String.ends_with?(path, ".tar.xz") do
      case System.cmd("xz", ["-dc", "--memlimit-decompress=#{@xz_memlimit}", path],
             stderr_to_stdout: true
           ) do
        {tar_bytes, 0} when byte_size(tar_bytes) <= @max_decompressed_bytes ->
          {:ok, tar_bytes}

        {_tar_bytes, 0} ->
          {:error, "xz archive decompresses to more than #{@max_decompressed_bytes} bytes"}

        {message, _} ->
          {:error, "invalid xz archive: #{String.trim(message)}"}
      end
    else
      {:ok, bytes}
    end
  rescue
    ErlangError -> {:error, "xz executable is required for .tar.xz archives"}
  end

  defp inventory_mode(nil, false),
    do: {:error, "destination migration inventory is required; use --artifact-only explicitly"}

  defp inventory_mode(nil, true), do: :ok
  defp inventory_mode(path, false) when is_binary(path), do: :ok

  defp inventory_mode(path, true) when is_binary(path),
    do: {:error, "destination inventory and artifact-only are mutually exclusive"}

  defp validate_inventory(nil, true, _), do: {:ok, "artifact-only"}

  defp validate_inventory(path, _, expected) do
    with {:ok, bytes} <- File.read(path),
         {:ok, actual} <- decode_inventory(bytes),
         :ok <- compare_migrations(actual, expected),
         do: {:ok, "destination-inventory"}
  end

  defp compare_migrations(actual, expected) do
    cond do
      actual == expected ->
        :ok

      Enum.take(expected, length(actual)) == actual ->
        {:error, "destination migration inventory is behind"}

      Enum.take(actual, length(expected)) == expected ->
        {:error, "destination migration inventory is ahead"}

      true ->
        {:error, "destination migration inventory differs"}
    end
  end

  defp dirty_policy(%{"source" => %{"dirty" => false}}, _), do: :ok
  defp dirty_policy(%{"source" => %{"dirty" => true}}, true), do: :ok

  defp dirty_policy(%{"source" => %{"dirty" => true}}, false),
    do: {:error, "dirty source is rejected without explicit override"}

  defp classification(%{"source" => %{"dirty" => true}}), do: "non-transferable-dirty-evidence"
  defp classification(_), do: "clean-source-candidate"

  defp validate_migrations(list) do
    paths =
      Enum.map(list, fn
        %{"path" => path, "sha256" => sha} when is_binary(path) and is_binary(sha) -> {path, sha}
        _ -> :invalid
      end)

    cond do
      :invalid in paths ->
        {:error, "invalid migration inventory entry"}

      Enum.any?(paths, fn {path, sha} ->
        not Regex.match?(~r|\Apriv/repo/migrations/[0-9]{14}_[a-z0-9_]+\.exs\z|, path) or
            not Regex.match?(~r/\A[0-9a-f]{64}\z/, sha)
      end) ->
        {:error, "invalid migration inventory entry"}

      Enum.map(paths, &elem(&1, 0)) != Enum.sort(Enum.map(paths, &elem(&1, 0))) ->
        {:error, "migration inventory must be ordered"}

      length(paths) != length(Enum.uniq_by(paths, &elem(&1, 0))) ->
        {:error, "duplicate migration inventory path"}

      true ->
        :ok
    end
  end

  defp migration_json(%{"path" => path, "sha256" => sha}),
    do: "{\"path\":" <> json(path) <> ",\"sha256\":" <> json(sha) <> "}"

  defp json(value), do: IO.iodata_to_binary(:json.encode(value))

  defp decode_json(bytes) do
    try do
      {:ok, :json.decode(bytes)}
    rescue
      _ -> {:error, "malformed JSON"}
    end
  end

  defp exact_keys(value, keys) when is_map(value),
    do:
      if(Map.keys(value) |> Enum.sort() == Enum.sort(keys),
        do: :ok,
        else: {:error, "unexpected or missing inventory keys"}
      )

  defp exact_keys(_, _), do: {:error, "inventory must be an object"}
  defp equal(value, value, _), do: :ok
  defp equal(_, _, name), do: {:error, "#{name} mismatch"}
end
