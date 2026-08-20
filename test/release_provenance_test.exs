ExUnit.start()
Code.require_file("../lib/spruce_goose/release_provenance.ex", __DIR__)

defmodule SpruceGoose.ReleaseProvenanceTest do
  use ExUnit.Case, async: true
  alias SpruceGoose.ReleaseProvenance, as: P

  @sha_a String.duplicate("a", 64)
  @sha_b String.duplicate("b", 64)
  @commit String.duplicate("c", 40)
  @tree String.duplicate("d", 40)

  setup do
    migrations = [
      %{
        "path" => "priv/repo/migrations/20260705142134_spike_init_extensions_1.exs",
        "sha256" => @sha_a
      },
      %{"path" => "priv/repo/migrations/20260705142135_spike_init.exs", "sha256" => @sha_b}
    ]

    provenance = %{
      "build" => %{
        "builder" => "release-bot@example.invalid",
        "time_utc" => "2026-08-13T11:18:13Z"
      },
      "governed" => %{"task" => "tsk-20260813T111813Z-19e119cb", "transaction" => "txn-release"},
      "migration_set_sha256" => P.migration_set_digest(migrations),
      "migrations" => migrations,
      "schema" => P.provenance_schema(),
      "source" => %{"commit" => @commit, "dirty" => false, "tree" => @tree},
      "toolchain" => %{"elixir" => "1.19.5", "erlang" => "28.3.1", "mix" => "1.19.5"}
    }

    receipt = %{
      "archive" => %{
        "filename" => "spruce-goose-0.1.0.tar.xz",
        "sha256" => @sha_a,
        "size_bytes" => 123
      },
      "build_time_utc" => provenance["build"]["time_utc"],
      "elixir_version" => provenance["toolchain"]["elixir"],
      "migration_set_sha256" => provenance["migration_set_sha256"],
      "otp_version" => provenance["toolchain"]["erlang"],
      "provenance_sha256" => @sha_b,
      "schema" => P.receipt_schema(),
      "source" => Map.take(provenance["source"], ["commit", "tree"])
    }

    %{provenance: provenance, receipt: receipt}
  end

  test "canonical provenance and receipt round trip exactly", %{provenance: p, receipt: r} do
    assert {:ok, pb} = P.encode_provenance(p)
    assert {:ok, ^p} = P.decode_provenance(pb)
    assert {:ok, rb} = P.encode_receipt(r)
    assert {:ok, ^r} = P.decode_receipt(rb)
  end

  test "every provenance object is recursively closed", %{provenance: p} do
    objects = [
      {[], "schema"},
      {[], "extra"},
      {["source"], "commit"},
      {["source"], "extra"},
      {["build"], "builder"},
      {["build"], "extra"},
      {["governed"], "task"},
      {["governed"], "extra"},
      {["toolchain"], "elixir"},
      {["toolchain"], "extra"},
      {["migrations", 0], "path"},
      {["migrations", 0], "extra"}
    ]

    for {path, key} <- objects do
      changed =
        if key == "extra",
          do: put_at(p, path, &Map.put(&1, key, true)),
          else: put_at(p, path, &Map.delete(&1, key))

      assert {:error, _} = P.encode_provenance(changed), "accepted #{inspect(path ++ [key])}"
    end
  end

  test "rejects malformed and noncanonical provenance JSON", %{provenance: p} do
    assert {:error, "malformed JSON"} = P.decode_provenance("{")
    assert {:ok, bytes} = P.encode_provenance(p)
    assert {:error, "noncanonical JSON"} = P.decode_provenance(String.trim_trailing(bytes))
    assert {:error, "noncanonical JSON"} = P.decode_provenance(" " <> bytes)
  end

  test "rejects invalid source, task, time, toolchain and migration values", %{provenance: p} do
    invalid = [
      put_in(p, ["source", "commit"], "ABC"),
      put_in(p, ["source", "tree"], String.duplicate("g", 40)),
      put_in(p, ["source", "dirty"], "false"),
      put_in(p, ["governed", "task"], "19e119cb"),
      put_in(p, ["build", "time_utc"], "2026-08-13T11:18:13+00:00"),
      put_in(p, ["build", "time_utc"], "2026-02-30T11:18:13Z"),
      put_in(p, ["toolchain", "elixir"], ""),
      put_in(p, ["toolchain", "erlang"], 28),
      put_in(p, ["migrations", Access.at(0), "path"], "../migration.exs"),
      put_in(p, ["migrations", Access.at(0), "sha256"], String.duplicate("A", 64))
    ]

    for value <- invalid, do: assert({:error, _} = P.encode_provenance(value))
  end

  test "rejects empty duplicate unordered migrations and wrong migration-set digest", %{
    provenance: p
  } do
    assert {:error, _} = P.encode_provenance(%{p | "migrations" => []})
    duplicate = %{p | "migrations" => [hd(p["migrations"]), hd(p["migrations"])]}

    duplicate = %{
      duplicate
      | "migration_set_sha256" => P.migration_set_digest(duplicate["migrations"])
    }

    assert {:error, _} = P.encode_provenance(duplicate)
    unordered = %{p | "migrations" => Enum.reverse(p["migrations"])}

    unordered = %{
      unordered
      | "migration_set_sha256" => P.migration_set_digest(unordered["migrations"])
    }

    assert {:error, _} = P.encode_provenance(unordered)

    assert {:error, "invalid migration_set_sha256"} =
             P.encode_provenance(%{p | "migration_set_sha256" => @sha_a})
  end

  test "receipt is recursively closed and rejects paths and malformed digests", %{receipt: r} do
    for changed <- [
          Map.delete(r, "schema"),
          Map.put(r, "extra", true),
          update_in(r["archive"], &Map.delete(&1, "filename")),
          update_in(r["archive"], &Map.put(&1, "extra", true))
        ] do
      assert {:error, _} = P.encode_receipt(changed)
    end

    for filename <- ["", ".", "..", "dir/archive.tar.gz", "../archive.tar.gz"] do
      assert {:error, "invalid archive.filename"} =
               P.encode_receipt(put_in(r, ["archive", "filename"], filename))
    end

    assert {:error, _} = P.encode_receipt(put_in(r, ["archive", "sha256"], "abc"))
    assert {:error, _} = P.encode_receipt(put_in(r, ["archive", "size_bytes"], 0))
    assert {:error, _} = P.encode_receipt(%{r | "provenance_sha256" => String.duplicate("A", 64)})
    assert {:error, "malformed JSON"} = P.decode_receipt("not-json")
    assert {:ok, bytes} = P.encode_receipt(r)
    assert {:error, "noncanonical JSON"} = P.decode_receipt(String.trim_trailing(bytes))
  end

  defp put_at(value, [], fun), do: fun.(value)

  defp put_at(value, [key | rest], fun) when is_binary(key),
    do: Map.update!(value, key, &put_at(&1, rest, fun))

  defp put_at(value, [index | rest], fun) when is_integer(index),
    do: List.update_at(value, index, &put_at(&1, rest, fun))
end
