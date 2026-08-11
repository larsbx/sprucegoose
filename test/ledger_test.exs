defmodule SpruceGoose.LedgerTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Ledger

  @id "tsk-20260727T041500Z-1234abcd"

  test "imports a typed Tuxedo ledger idempotently and proves exact parity" do
    previous_root = Application.get_env(:spruce_goose, :ledger_import_root)
    previous_recovery = Application.get_env(:spruce_goose, :ledger_recovery_mode)
    previous_recovery_database = Application.get_env(:spruce_goose, :ledger_recovery_database)
    Application.put_env(:spruce_goose, :ledger_import_root, System.tmp_dir!())
    Application.put_env(:spruce_goose, :ledger_recovery_mode, true)
    Application.put_env(:spruce_goose, :ledger_recovery_database, Repo.config()[:database])
    Repo.query!("UPDATE authority_instance_identity SET purpose = 'recovery' WHERE singleton")

    on_exit(fn ->
      restore(:ledger_import_root, previous_root)
      restore(:ledger_recovery_mode, previous_recovery)
      restore(:ledger_recovery_database, previous_recovery_database)
    end)

    path =
      Path.join(System.tmp_dir!(), "sprucegoose-ledger-#{System.unique_integer([:positive])}")

    line =
      "(A) 2026-07-27 Import the ledger id:#{@id} schema:task-v2 type:task " <>
        "dod:Every_record_matches ref:project:pi ref:roadmap:buzz " <>
        "ref:workflow:import status:active"

    File.write!(path, line <> "\n")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{tasks: 1, dependencies: 0, parity: true}} =
             Executor.run({:import_ledger, path})

    assert {:ok, %{tasks: 1, dependencies: 0, parity: true}} =
             Executor.run({:import_ledger, path})

    assert {:ok, %{tasks: 1, dependencies: 0, parity: true}} =
             Executor.run({:parity_ledger, path})

    File.write!(path, String.replace(line, "Every_record_matches", "Changed") <> "\n")
    assert {:error, "ledger parity failed:" <> _} = Executor.run({:parity_ledger, path})
    assert {:ok, %{tasks: 1, parity: true}} = Executor.run({:import_ledger, path})
  end

  test "preserves grandfathered missing DoD as explicit import metadata" do
    assert {:ok, task} =
             Ledger.parse(
               "2026-07-23 Old task id:#{@id} ref:project:pi ref:roadmap:buzz " <>
                 "ref:workflow:import status:queued"
             )

    assert task.encoded_definition_of_done == nil
    assert task.definition_of_done =~ "Grandfathered legacy task"
  end

  test "rejects unknown ledger schema, type, and status values" do
    base =
      "2026-07-27 Example id:#{@id} schema:task-v2 type:task dod:Done status:queued " <>
        "ref:project:pi ref:roadmap:buzz ref:workflow:import"

    for {from, to, message} <- [
          {"schema:task-v2", "schema:task-v3", "unknown task schema"},
          {"type:task", "type:future", "unknown task type"},
          {"status:queued", "status:future", "unknown task status"}
        ] do
      assert {:error, error} = Ledger.parse(String.replace(base, from, to))
      assert error =~ message
    end
  end

  defp restore(key, nil), do: Application.delete_env(:spruce_goose, key)
  defp restore(key, value), do: Application.put_env(:spruce_goose, key, value)
end
