defmodule SpruceGoose.ReauditRegressionTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Ledger
  alias SpruceGoose.Workflows.{Dependency, Task}

  @a "tsk-20260727T104500Z-11111111"
  @b "tsk-20260727T104501Z-22222222"
  @c "tsk-20260727T104502Z-33333333"

  test "refresh preserves native metadata, invalidates stale writes, and locks after cutover" do
    path = ledger([line(@a, "Original")])
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{parity: true}} = Ledger.import(path)
    {:ok, stale} = read_task(@a)
    assert {:ok, _} = Executor.run({:link_task, @a, "evidence", "/tmp/native"})
    {:ok, before_refresh} = read_task(@a)

    File.write!(path, line(@a, "Refreshed") <> "\n")
    assert {:ok, %{parity: true}} = Ledger.import(path)
    {:ok, refreshed} = read_task(@a)

    assert refreshed.title == "Refreshed"
    assert refreshed.lock_version > before_refresh.lock_version
    assert [%{"kind" => "evidence", "value" => "/tmp/native"}] = refreshed.input["references"]

    assert {:error, _} =
             stale
             |> Ash.Changeset.for_update(:revise, %{title: "stale write"})
             |> Ash.update()

    sql!("UPDATE spruce_goose_authority SET mode = 'ash', cutover_at = now() WHERE id = TRUE")
    assert {:error, "ledger import is disabled while ash is authoritative"} = Ledger.import(path)
    assert {:ok, %{title: "Refreshed"}} = Executor.run({:show_task, @a})
  end

  test "refresh removes obsolete imported dependencies and preserves native edges" do
    path =
      ledger([
        line(@a, "A"),
        line(@b, "B", [@a]),
        line(@c, "C")
      ])

    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{dependencies: 1}} = Ledger.import(path)

    {:ok, b} = read_task(@b)
    {:ok, c} = read_task(@c)
    assert {:ok, _} = Ash.create(Dependency, %{predecessor_id: b.id, successor_id: c.id})

    File.write!(path, Enum.join([line(@a, "A"), line(@b, "B"), line(@c, "C")], "\n") <> "\n")
    assert {:ok, %{dependencies: 0, parity: true}} = Ledger.import(path)

    assert [[0]] = sql!("SELECT count(*) FROM task_dependencies WHERE source = 'tuxedo'").rows
    assert [[1]] = sql!("SELECT count(*) FROM task_dependencies WHERE source = 'native'").rows
  end

  test "lifecycle gates are explicit and diagnosis completion is evidence-backed" do
    path =
      ledger([
        String.replace(line(@a, "Diagnosis"), "type:task", "type:diagnosis"),
        line(@b, "Cancellation")
      ])

    on_exit(fn -> File.rm(path) end)
    assert {:ok, %{parity: true}} = Ledger.import(path)

    assert {:error, "task must be ready"} =
             Executor.run({:transition_task, @a, :in_progress, nil})

    assert {:ok, %{state: :ready}} = Executor.run({:transition_task, @a, :ready, nil})
    assert {:ok, %{state: :in_progress}} = Executor.run({:transition_task, @a, :in_progress, nil})

    assert {:ok, waiting} =
             Executor.run({:transition_task, @a, :waiting, "collecting evidence"})

    assert waiting.state == :waiting
    assert waiting.wait_reason == "collecting evidence"

    assert {:ok, %{state: :ready}} = Executor.run({:transition_task, @a, :ready, nil})
    assert {:ok, %{state: :in_progress}} = Executor.run({:transition_task, @a, :in_progress, nil})
    assert {:error, _} = Executor.run({:transition_task, @a, :completed, nil})

    for kind <- ["finding", "regression", "sop"] do
      assert {:ok, _} = Executor.run({:link_task, @a, kind, "/tmp/#{kind}"})
    end

    assert {:ok, todo} = Executor.run({:add_todo, @a, "Verify remediation"})
    assert {:error, _} = Executor.run({:transition_task, @a, :completed, nil})
    assert {:ok, %{completed: true}} = Executor.run({:complete_todo, @a, todo.id})
    assert {:ok, completed} = Executor.run({:transition_task, @a, :completed, nil})
    assert completed.state == :completed

    assert Enum.map(completed.references, & &1["kind"]) |> Enum.sort() ==
             ["finding", "regression", "sop"]

    assert completed.import_provenance.source == "tuxedo"

    assert {:ok, cancelled} =
             Executor.run({:transition_task, @b, :cancelled, "superseded"})

    assert cancelled.cancel_reason == "superseded"
  end

  defp line(id, title, dependencies \\ []) do
    dependency_text = Enum.map_join(dependencies, "", &" ref:depends-on:#{&1}")

    "2026-07-27 #{title} id:#{id} schema:task-v2 type:task dod:Verified status:queued " <>
      "ref:project:pi ref:roadmap:buzz ref:workflow:import" <> dependency_text
  end

  defp ledger(lines) do
    path = Path.join(System.tmp_dir!(), "reaudit-ledger-#{System.unique_integer([:positive])}")
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp read_task(id) do
    Task
    |> Ash.Query.filter_input(task_id: id)
    |> Ash.read_one()
  end

  defp sql!(statement), do: Ecto.Adapters.SQL.query!(SpruceGoose.Repo, statement, [])
end
