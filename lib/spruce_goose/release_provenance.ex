defmodule SpruceGoose.ReleaseProvenance do
  @moduledoc "Strict canonical governed release provenance and receipt codec."

  @provenance_schema "spruce-goose-release-provenance-v1"
  @receipt_schema "spruce-goose-release-receipt-v1"
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @git_oid ~r/\A[0-9a-f]{40}\z/
  @task ~r/\Atsk-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}\z/
  @utc ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/
  @migration ~r|\Apriv/repo/migrations/[0-9]{14}_[a-z0-9_]+\.exs\z|

  def provenance_schema, do: @provenance_schema
  def receipt_schema, do: @receipt_schema

  def decode_provenance(bytes) when is_binary(bytes) do
    with {:ok, value} <- decode_json(bytes),
         :ok <- validate_provenance(value),
         {:ok, canonical} <- encode_provenance(value),
         :ok <- exact(bytes, canonical) do
      {:ok, value}
    end
  end

  def decode_receipt(bytes) when is_binary(bytes) do
    with {:ok, value} <- decode_json(bytes),
         :ok <- validate_receipt(value),
         {:ok, canonical} <- encode_receipt(value),
         :ok <- exact(bytes, canonical) do
      {:ok, value}
    end
  end

  def encode_provenance(value) do
    with :ok <- validate_provenance(value) do
      {:ok,
       "{\"build\":" <>
         object(value["build"], ["builder", "time_utc"]) <>
         ",\"governed\":" <>
         object(value["governed"], ["task", "transaction"]) <>
         ",\"migration_set_sha256\":" <>
         string(value["migration_set_sha256"]) <>
         ",\"migrations\":[" <>
         Enum.map_join(value["migrations"], ",", &object(&1, ["path", "sha256"])) <>
         "],\"schema\":" <>
         string(value["schema"]) <>
         ",\"source\":" <>
         object(value["source"], ["commit", "dirty", "tree"]) <>
         ",\"toolchain\":" <> object(value["toolchain"], ["elixir", "erlang", "mix"]) <> "}\n"}
    end
  end

  def encode_receipt(value) do
    with :ok <- validate_receipt(value) do
      {:ok,
       "{\"archive\":" <>
         object(value["archive"], ["filename", "sha256"]) <>
         ",\"provenance_sha256\":" <>
         string(value["provenance_sha256"]) <>
         ",\"schema\":" <> string(value["schema"]) <> "}\n"}
    end
  end

  def migration_set_digest(migrations) when is_list(migrations) do
    migrations
    |> Enum.map_join(fn migration ->
      migration["path"] <> <<0>> <> migration["sha256"] <> "\n"
    end)
    |> sha256()
  end

  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp validate_provenance(value) do
    with :ok <-
           keys(value, [
             "build",
             "governed",
             "migration_set_sha256",
             "migrations",
             "schema",
             "source",
             "toolchain"
           ]),
         :ok <- equal(value["schema"], @provenance_schema, "schema"),
         :ok <- keys(value["source"], ["commit", "dirty", "tree"]),
         :ok <- format(value["source"]["commit"], @git_oid, "source.commit"),
         :ok <- bool(value["source"]["dirty"], "source.dirty"),
         :ok <- format(value["source"]["tree"], @git_oid, "source.tree"),
         :ok <- keys(value["build"], ["builder", "time_utc"]),
         :ok <- nonempty(value["build"]["builder"], "build.builder"),
         :ok <- utc(value["build"]["time_utc"]),
         :ok <- keys(value["governed"], ["task", "transaction"]),
         :ok <- format(value["governed"]["task"], @task, "governed.task"),
         :ok <- nonempty(value["governed"]["transaction"], "governed.transaction"),
         :ok <- keys(value["toolchain"], ["elixir", "erlang", "mix"]),
         :ok <- versions(value["toolchain"]),
         :ok <- migrations(value["migrations"]),
         :ok <- format(value["migration_set_sha256"], @sha256, "migration_set_sha256"),
         :ok <-
           equal(
             value["migration_set_sha256"],
             migration_set_digest(value["migrations"]),
             "migration_set_sha256"
           ) do
      :ok
    end
  end

  defp validate_receipt(value) do
    with :ok <- keys(value, ["archive", "provenance_sha256", "schema"]),
         :ok <- equal(value["schema"], @receipt_schema, "schema"),
         :ok <- keys(value["archive"], ["filename", "sha256"]),
         :ok <- filename(value["archive"]["filename"]),
         :ok <- format(value["archive"]["sha256"], @sha256, "archive.sha256"),
         :ok <- format(value["provenance_sha256"], @sha256, "provenance_sha256") do
      :ok
    end
  end

  defp migrations(list) when is_list(list) and list != [] do
    with :ok <- each_migration(list) do
      paths = Enum.map(list, & &1["path"])

      cond do
        paths != Enum.sort(paths) -> {:error, "migrations must be strictly ordered"}
        length(paths) != length(Enum.uniq(paths)) -> {:error, "duplicate migration path"}
        true -> :ok
      end
    end
  end

  defp migrations(_), do: {:error, "migrations must be a non-empty list"}

  defp each_migration(list) do
    Enum.reduce_while(list, :ok, fn migration, :ok ->
      case with :ok <- keys(migration, ["path", "sha256"]),
                :ok <- format(migration["path"], @migration, "migration.path"),
                :ok <- format(migration["sha256"], @sha256, "migration.sha256"),
                do: :ok do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp versions(toolchain) do
    Enum.reduce_while(["elixir", "erlang", "mix"], :ok, fn key, :ok ->
      case nonempty(toolchain[key], "toolchain." <> key) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp decode_json(bytes) do
    try do
      {:ok, :json.decode(bytes)}
    rescue
      _ -> {:error, "malformed JSON"}
    catch
      _, _ -> {:error, "malformed JSON"}
    end
  end

  defp keys(value, expected) when is_map(value) do
    if Map.keys(value) |> Enum.sort() == Enum.sort(expected),
      do: :ok,
      else: {:error, "unexpected or missing keys"}
  end

  defp keys(_, _), do: {:error, "expected object"}

  defp format(value, regex, name) when is_binary(value),
    do: if(Regex.match?(regex, value), do: :ok, else: {:error, "invalid #{name}"})

  defp format(_, _, name), do: {:error, "invalid #{name}"}

  defp nonempty(value, _name) when is_binary(value) and byte_size(value) > 0,
    do: if(String.valid?(value), do: :ok, else: {:error, "invalid UTF-8"})

  defp nonempty(_, name), do: {:error, "invalid #{name}"}
  defp bool(value, _) when is_boolean(value), do: :ok
  defp bool(_, name), do: {:error, "invalid #{name}"}
  defp equal(a, a, _), do: :ok
  defp equal(_, _, name), do: {:error, "invalid #{name}"}
  defp exact(a, a), do: :ok
  defp exact(_, _), do: {:error, "noncanonical JSON"}

  defp utc(value) do
    with :ok <- format(value, @utc, "build.time_utc"),
         {:ok, dt, 0} <- DateTime.from_iso8601(value),
         true <- dt.time_zone == "Etc/UTC" do
      :ok
    else
      _ -> {:error, "invalid build.time_utc"}
    end
  end

  defp filename(value) when is_binary(value) and byte_size(value) > 0 do
    if Path.basename(value) == value and value not in [".", ".."],
      do: :ok,
      else: {:error, "invalid archive.filename"}
  end

  defp filename(_), do: {:error, "invalid archive.filename"}

  defp object(map, ordered_keys),
    do:
      "{" <>
        Enum.map_join(ordered_keys, ",", fn key -> string(key) <> ":" <> json(map[key]) end) <>
        "}"

  defp json(value) when is_binary(value), do: string(value)
  defp json(value) when is_boolean(value), do: to_string(value)
  defp string(value), do: IO.iodata_to_binary(:json.encode(value))
end
