defmodule SpruceGoose.Knowledge do
  @moduledoc """
  Imports preserved historical graph generations into a read-only projection.

  Operational workflow tables remain the sole task authority.
  """

  alias SpruceGoose.Knowledge.{Generation, Node, Relation}
  alias SpruceGoose.Repo

  def import_historical_graph(%{complete?: false}), do: {:error, :incomplete_generation}

  def import_historical_graph(fixture) do
    # AUTHORIZATION: non-CLI historical fixture importer used only by governed intake.
    Repo.transaction(fn ->
      # AUTHORIZATION: serialized within the governed historical import transaction.
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext('spruce_goose_knowledge_import'))")

      case {generation_by_digest(fixture.source_digest), active_record()} do
        {%{source_revision: revision} = generation, _} when revision == fixture.source_revision ->
          {result(generation, %{documents: 0, sections: 0, relations: 0}), []}

        {_, %{source_revision: revision}} when revision >= fixture.source_revision ->
          Repo.rollback(:stale_generation)

        {nil, active} ->
          import_new(fixture, active)

        {_generation, _active} ->
          Repo.rollback(:source_metadata_mismatch)
      end
    end)
    |> unwrap_transaction()
  end

  def active_generation do
    Generation
    |> Ash.Query.filter_input(%{state: :active})
    |> Ash.read_one!()
    |> generation_result()
  end

  def projected_nodes(generation_id) do
    Node
    |> Ash.Query.filter_input(%{generation_id: generation_id})
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!()
    |> Enum.map(&Map.take(&1, [:id, :label, :source_file, :source_location, :origin]))
  end

  def projected_relations(generation_id) do
    Relation
    |> Ash.Query.filter_input(%{generation_id: generation_id})
    |> Ash.Query.sort(position: :asc)
    |> Ash.read!()
    |> Enum.map(
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
  end

  defp import_new(fixture, active) do
    {_, retire_notifications} =
      if active do
        Ash.update!(active, %{}, action: :retire, return_notifications?: true)
      else
        {nil, []}
      end

    {generation, generation_notifications} =
      Ash.create!(
        Generation,
        %{
          source: fixture.source,
          source_revision: fixture.source_revision,
          source_digest: fixture.source_digest,
          state: :active
        },
        return_notifications?: true
      )

    node_notifications =
      Enum.with_index(fixture.nodes, 1)
      |> Enum.flat_map(fn {node, position} ->
        input =
          node
          |> Map.take([:id, :label, :source_file, :source_location, :origin])
          |> Map.merge(%{generation_id: generation.id, position: position})

        {_node, notifications} = Ash.create!(Node, input, return_notifications?: true)
        notifications
      end)

    relation_notifications =
      Enum.with_index(fixture.edges, 1)
      |> Enum.flat_map(fn {relation, position} ->
        input =
          relation
          |> Map.take([
            :source,
            :target,
            :relation,
            :confidence,
            :source_file,
            :source_location,
            :origin
          ])
          |> Map.merge(%{generation_id: generation.id, position: position})

        {_relation, notifications} = Ash.create!(Relation, input, return_notifications?: true)
        notifications
      end)

    {
      result(generation, %{
        documents: length(fixture.nodes),
        sections: 0,
        relations: length(fixture.edges)
      }),
      retire_notifications ++
        generation_notifications ++ node_notifications ++ relation_notifications
    }
  end

  defp active_record do
    Generation
    |> Ash.Query.filter_input(%{state: :active})
    |> Ash.read_one!()
  end

  defp generation_by_digest(digest) do
    Generation
    |> Ash.Query.filter_input(%{source_digest: digest})
    |> Ash.read_one!()
  end

  defp result(generation, inserted) do
    generation
    |> generation_result()
    |> Map.put(:inserted, inserted)
  end

  defp generation_result(nil), do: nil

  defp generation_result(generation) do
    %{
      generation_id: generation.id,
      source_digest: generation.source_digest,
      source_revision: generation.source_revision,
      state: generation.state
    }
  end

  defp unwrap_transaction({:ok, {result, notifications}}) do
    Ash.Notifier.notify(notifications)
    {:ok, result}
  end

  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
