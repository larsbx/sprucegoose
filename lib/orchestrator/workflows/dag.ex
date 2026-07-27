defmodule Orchestrator.Workflows.Dag do
  @moduledoc false

  alias Orchestrator.Workflows.TaskDefinition

  def validate(nil), do: :ok
  def validate([]), do: {:error, "must contain at least one task"}

  def validate(tasks) when is_list(tasks) do
    ids = Enum.map(tasks, &task_id/1)
    id_set = MapSet.new(ids)

    with :ok <- unique(ids, id_set),
         :ok <- valid_dependencies(tasks, id_set),
         {:ok, _ordered_ids} <- order(tasks) do
      :ok
    end
  end

  def order(tasks) when is_list(tasks) do
    by_id = Map.new(tasks, &{task_id(&1), &1})
    indegree = Map.new(tasks, &{task_id(&1), length(depends_on(&1))})

    dependents =
      Enum.reduce(tasks, %{}, fn task, acc ->
        Enum.reduce(depends_on(task), acc, fn dependency, inner ->
          Map.update(inner, dependency, [task_id(task)], &[task_id(task) | &1])
        end)
      end)

    ready =
      indegree
      |> Enum.filter(fn {_id, degree} -> degree == 0 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    case walk(ready, indegree, dependents, []) do
      {:ok, ids} when map_size(by_id) == length(ids) ->
        {:ok, Enum.map(ids, &Map.fetch!(by_id, &1))}

      _ ->
        {:error, "dependency graph must be acyclic"}
    end
  end

  defp walk([], indegree, _dependents, ordered) do
    if Enum.all?(indegree, fn {_id, degree} -> degree == 0 end) do
      {:ok, Enum.reverse(ordered)}
    else
      :cycle
    end
  end

  defp walk([id | rest], indegree, dependents, ordered) do
    {next_indegree, newly_ready} =
      dependents
      |> Map.get(id, [])
      |> Enum.sort()
      |> Enum.reduce({indegree, []}, fn dependent, {degrees, ready} ->
        degree = Map.fetch!(degrees, dependent) - 1

        {Map.put(degrees, dependent, degree),
         if(degree == 0, do: [dependent | ready], else: ready)}
      end)

    walk(Enum.sort(rest ++ newly_ready), next_indegree, dependents, [id | ordered])
  end

  defp unique(ids, id_set) do
    if length(ids) == MapSet.size(id_set), do: :ok, else: {:error, "task ids must be unique"}
  end

  defp valid_dependencies(tasks, id_set) do
    Enum.reduce_while(tasks, :ok, fn task, :ok ->
      id = task_id(task)
      dependencies = depends_on(task)

      cond do
        id in dependencies ->
          {:halt, {:error, "task #{inspect(id)} cannot depend on itself"}}

        missing = Enum.find(dependencies, &(not MapSet.member?(id_set, &1))) ->
          {:halt, {:error, "task #{inspect(id)} depends on unknown task #{inspect(missing)}"}}

        length(dependencies) != MapSet.size(MapSet.new(dependencies)) ->
          {:halt, {:error, "task #{inspect(id)} has duplicate dependencies"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp task_id(%TaskDefinition{id: id}), do: id
  defp task_id(%{id: id}), do: id
  defp task_id(%{"id" => id}), do: id

  defp depends_on(%TaskDefinition{depends_on: dependencies}), do: dependencies
  defp depends_on(%{depends_on: dependencies}), do: dependencies
  defp depends_on(%{"depends_on" => dependencies}), do: dependencies
  defp depends_on(_), do: []
end
