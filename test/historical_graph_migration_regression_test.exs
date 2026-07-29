defmodule SpruceGoose.HistoricalGraphMigrationRegressionTest do
  use SpruceGoose.DataCase

  alias SpruceGoose.Knowledge

  @fixture Path.join(__DIR__, "fixtures/historical_graphify_generation.exs")

  test "historical Graphify generation migrates exactly once without changing task authority" do
    fixture = fixture()
    task_count = task_count()

    assert {:ok, first} = Knowledge.import_historical_graph(fixture)
    assert {:ok, replay} = Knowledge.import_historical_graph(fixture)

    assert replay.generation_id == first.generation_id
    assert replay.inserted == %{documents: 0, sections: 0, relations: 0}
    assert first.source_digest == fixture.source_digest
    assert first.state == :active

    assert Knowledge.projected_nodes(first.generation_id) ==
             Enum.map(
               fixture.nodes,
               &Map.take(&1, [:id, :label, :source_file, :source_location, :origin])
             )

    assert Knowledge.projected_relations(first.generation_id) ==
             Enum.map(
               fixture.edges,
               &Map.take(&1, [
                 :source,
                 :target,
                 :relation,
                 :confidence,
                 :source_file,
                 :source_location,
                 :origin
               ])
             )

    assert task_count() == task_count
  end

  test "stale or incomplete historical generations fail closed and retain the active generation" do
    fixture = fixture()
    assert {:ok, active} = Knowledge.import_historical_graph(fixture)

    stale = %{fixture | source_revision: "historical-2026-07-25"}
    incomplete = %{fixture | source_revision: "historical-2026-07-27", complete?: false}

    assert {:error, :stale_generation} = Knowledge.import_historical_graph(stale)
    assert {:error, :incomplete_generation} = Knowledge.import_historical_graph(incomplete)
    assert Knowledge.active_generation().generation_id == active.generation_id
    assert Knowledge.active_generation().source_digest == fixture.source_digest
  end

  defp fixture do
    {fixture, _binding} = Code.eval_file(@fixture)
    fixture
  end

  defp task_count do
    %{rows: [[count]]} = Repo.query!("SELECT count(*) FROM workflow_tasks")
    count
  end
end
