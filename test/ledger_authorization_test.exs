defmodule SpruceGoose.LedgerAuthorizationTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Actors.{Actor, Grant}
  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Ledger
  alias SpruceGoose.Repo

  @id "tsk-20260727T041500Z-1234abcd"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "sprucegoose-ledger-root-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    previous = %{
      root: Application.get_env(:spruce_goose, :ledger_import_root),
      bytes: Application.get_env(:spruce_goose, :ledger_max_bytes),
      lines: Application.get_env(:spruce_goose, :ledger_max_lines),
      recovery: Application.get_env(:spruce_goose, :ledger_recovery_mode),
      recovery_database: Application.get_env(:spruce_goose, :ledger_recovery_database)
    }

    Application.put_env(:spruce_goose, :ledger_import_root, root)
    Application.put_env(:spruce_goose, :ledger_max_bytes, 1_024)
    Application.put_env(:spruce_goose, :ledger_max_lines, 2)
    Application.put_env(:spruce_goose, :ledger_recovery_mode, true)
    Application.put_env(:spruce_goose, :ledger_recovery_database, Repo.config()[:database])
    Repo.query!("UPDATE authority_instance_identity SET purpose = 'recovery' WHERE singleton")

    on_exit(fn ->
      File.rm_rf!(root)
      restore(:ledger_import_root, previous.root)
      restore(:ledger_max_bytes, previous.bytes)
      restore(:ledger_max_lines, previous.lines)
      restore(:ledger_recovery_mode, previous.recovery)
      restore(:ledger_recovery_database, previous.recovery_database)
    end)

    valid = Path.join(root, "ledger.txt")
    File.write!(valid, ledger_line() <> "\n")

    %{root: root, valid: valid}
  end

  test "authorization precedes filesystem and parity access", %{valid: valid, root: root} do
    ungranted =
      Ash.create!(Actor, %{
        name: "ledger-reader",
        kind: :agent,
        created_by: "test-system"
      })

    Ash.create!(Grant, %{
      actor_id: ungranted.id,
      role: :operator,
      scope: "project:pi",
      granted_by: "test-system"
    })

    missing = Path.join(root, "missing.txt")

    for path <- [valid, missing], operation <- [:parity_ledger, :import_ledger] do
      assert {:error, message} = Executor.run({operation, path}, ungranted.name)
      assert message =~ "require admin at global scope"
      refute message =~ path
      refute message =~ "enoent"
    end
  end

  test "import requires explicit recovery mode on a separate bound database", %{valid: valid} do
    Application.put_env(:spruce_goose, :ledger_recovery_mode, false)

    assert {:error, message} = Executor.run({:import_ledger, valid})
    assert message =~ "explicit offline recovery mode"

    Application.put_env(:spruce_goose, :ledger_recovery_mode, true)
    previous_live = Application.get_env(:spruce_goose, :ledger_live_database)
    Application.put_env(:spruce_goose, :ledger_live_database, Repo.config()[:database])
    on_exit(fn -> restore(:ledger_live_database, previous_live) end)

    # Runtime mutation cannot spoof the compile-time live authority identity.
    assert {:ok, _result} = Executor.run({:import_ledger, valid})

    Application.put_env(:spruce_goose, :ledger_recovery_database, "spoofed-name")
    assert {:error, message} = Executor.run({:import_ledger, valid})
    assert message =~ "bound to a different database"
  end

  test "bounded intake rejects out-of-root, symlink, non-regular, oversized, and over-line inputs",
       %{
         valid: valid,
         root: root
       } do
    outside = Path.join(System.tmp_dir!(), "outside-ledger-#{System.unique_integer([:positive])}")
    File.write!(outside, ledger_line() <> "\n")
    on_exit(fn -> File.rm(outside) end)

    symlink = Path.join(root, "ledger-link")
    File.ln_s!(valid, symlink)
    symlink_directory = Path.join(root, "linked-directory")
    File.ln_s!(System.tmp_dir!(), symlink_directory)
    through_symlink = Path.join(symlink_directory, Path.basename(outside))
    directory = Path.join(root, "directory")
    File.mkdir!(directory)
    fifo = Path.join(root, "fifo")
    {_, 0} = System.cmd("mkfifo", [fifo])
    oversized = Path.join(root, "oversized")
    File.write!(oversized, String.duplicate("x", 1_025))
    over_lines = Path.join(root, "over-lines")
    File.write!(over_lines, "one\ntwo\nthree\n")

    for {path, expected} <- [
          {outside, "configured root"},
          {symlink, "symlink"},
          {through_symlink, "symlink"},
          {directory, "regular file"},
          {fifo, "regular file"},
          {oversized, "byte limit"},
          {over_lines, "line limit"}
        ] do
      assert {:error, message} = Ledger.read(path)
      assert message =~ expected
    end
  end

  test "authorized recovery import records an immutable actor-bound receipt", %{valid: valid} do
    assert {:ok, result} = Executor.run({:import_ledger, valid})
    assert result.parity == true
    assert is_binary(result.receipt_id)
    assert result.actor_name == "test-system"
    assert is_binary(result.actor_id)

    assert %{rows: [[actor_id, actor_name, source_sha256]]} =
             Repo.query!(
               "SELECT actor_id::text, actor_name, source_sha256 FROM ledger_import_receipts WHERE id = $1::uuid",
               [Ecto.UUID.dump!(result.receipt_id)]
             )

    assert actor_id == result.actor_id
    assert actor_name == result.actor_name
    assert source_sha256 =~ ~r/^[0-9a-f]{64}$/

    assert {:error, %Postgrex.Error{}} =
             Repo.query(
               "UPDATE ledger_import_receipts SET actor_name = 'tampered' WHERE id = $1::uuid",
               [Ecto.UUID.dump!(result.receipt_id)],
               mode: :savepoint
             )

    assert {:error, %Postgrex.Error{}} =
             Repo.query(
               "DELETE FROM ledger_import_receipts WHERE id = $1::uuid",
               [Ecto.UUID.dump!(result.receipt_id)],
               mode: :savepoint
             )
  end

  test "failed import rolls back its immutable receipt", %{root: root} do
    invalid = Path.join(root, "invalid-ledger.txt")
    File.write!(invalid, ledger_line() <> "\n" <> ledger_line() <> "\n")
    before_count = Repo.aggregate(SpruceGoose.Ledger.ImportReceipt, :count)

    assert {:error, _reason} = Executor.run({:import_ledger, invalid})
    assert Repo.aggregate(SpruceGoose.Ledger.ImportReceipt, :count) == before_count
  end

  defp ledger_line do
    "2026-07-27 Import id:#{@id} schema:task-v2 type:task dod:Done status:queued " <>
      "ref:project:pi ref:roadmap:buzz ref:workflow:import"
  end

  defp restore(key, nil), do: Application.delete_env(:spruce_goose, key)
  defp restore(key, value), do: Application.put_env(:spruce_goose, key, value)
end
