defmodule Orchestrator.LedgerTest do
  use Orchestrator.DataCase, async: false

  alias Orchestrator.Ledger

  @id "tsk-20260727T041500Z-1234abcd"

  test "imports a typed Tuxedo ledger idempotently and proves exact parity" do
    path =
      Path.join(System.tmp_dir!(), "orchestrator-ledger-#{System.unique_integer([:positive])}")

    line =
      "(A) 2026-07-27 Import the ledger id:#{@id} schema:task-v2 type:task " <>
        "dod:Every_record_matches ref:project:pi ref:roadmap:buzz " <>
        "ref:workflow:import status:active"

    File.write!(path, line <> "\n")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{tasks: 1, dependencies: 0, parity: true}} = Ledger.import(path)
    assert {:ok, %{tasks: 1, dependencies: 0, parity: true}} = Ledger.import(path)
    assert {:ok, %{tasks: 1, dependencies: 0, parity: true}} = Ledger.parity(path)

    File.write!(path, String.replace(line, "Every_record_matches", "Changed") <> "\n")
    assert {:error, "ledger parity failed:" <> _} = Ledger.parity(path)
    assert {:ok, %{tasks: 1, parity: true}} = Ledger.import(path)
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
end
