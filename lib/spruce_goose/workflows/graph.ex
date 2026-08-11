defmodule SpruceGoose.Workflows.Graph do
  @moduledoc """
  Read-only PostgreSQL 19 property-graph queries over workflow dependencies.

  PostgreSQL supplies the authorized, workflow-scoped vertices and edges. The
  bounded traversal and topological dynamic programming run in memory so a
  dense DAG cannot make the database enumerate every possible path.
  """

  alias SpruceGoose.Repo
  alias SpruceGoose.Workflows.{Task, Workflow}

  @edge_rows """
  SELECT predecessor_id, successor_id
  FROM GRAPH_TABLE (
    sprucegoose_task_dependency_graph
    MATCH (predecessor IS task)-[edge IS dependency]->(successor IS task)
    WHERE predecessor.workflow_id = $1::uuid
      AND successor.workflow_id = $1::uuid
      AND edge.workflow_id = $1::uuid
    COLUMNS (
      predecessor.id AS predecessor_id,
      successor.id AS successor_id
    )
  )
  """

  @task_rows """
  SELECT id, task_id, title, state
  FROM workflow_tasks
  WHERE workflow_id = $1::uuid
  ORDER BY task_id
  """

  @doc "Incomplete direct and transitive predecessors of an authorized task."
  def blockers(%Task{} = task) do
    with {:ok, graph} <- load_graph(task.workflow_id),
         {:ok, distances} <- distances(graph.reverse, uuid!(task.id)) do
      {:ok, result_rows(graph.tasks, distances, &(&1.state != "completed"))}
    end
  end

  @doc "Direct and transitive successors affected by an authorized task."
  def impact(%Task{} = task) do
    with {:ok, graph} <- load_graph(task.workflow_id),
         {:ok, distances} <- distances(graph.forward, uuid!(task.id)) do
      {:ok, result_rows(graph.tasks, distances, fn _ -> true end)}
    end
  end

  @doc "The deterministic longest dependency path in an authorized workflow."
  def critical_path(%Workflow{} = workflow) do
    with {:ok, graph} <- load_graph(workflow.id),
         {:ok, path_ids, edge_count} <- longest_path(graph) do
      path = Enum.map(path_ids, &Map.fetch!(graph.tasks, &1))
      {:ok, %{edge_count: edge_count, task_count: length(path), path: path}}
    end
  end

  defp load_graph(workflow_id) do
    # AUTHORIZATION: callers authorize the task or workflow through Ash before
    # entering this module. Every query binds that authorized workflow UUID.
    id = uuid!(workflow_id)

    # AUTHORIZATION: both raw reads use only that bound workflow UUID.
    with {:ok, %{rows: edges}} <- Repo.query(@edge_rows, [id]),
         {:ok, %{rows: task_rows}} <- Repo.query(@task_rows, [id]) do
      tasks =
        Map.new(task_rows, fn [task_id, stable_id, title, state] ->
          {task_id, %{id: stable_id, title: title, state: state}}
        end)

      empty = Map.new(Map.keys(tasks), &{&1, []})

      forward =
        Enum.reduce(edges, empty, fn [predecessor, successor], adjacency ->
          Map.update!(adjacency, predecessor, &[successor | &1])
        end)

      reverse =
        Enum.reduce(edges, empty, fn [predecessor, successor], adjacency ->
          Map.update!(adjacency, successor, &[predecessor | &1])
        end)

      {:ok,
       %{
         tasks: tasks,
         forward: sort_adjacency(forward, tasks),
         reverse: sort_adjacency(reverse, tasks),
         edge_count: length(edges)
       }}
    else
      {:error, %Postgrex.Error{} = error} -> {:error, Exception.message(error)}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp sort_adjacency(adjacency, tasks) do
    Map.new(adjacency, fn {id, neighbours} ->
      {id, Enum.sort_by(neighbours, &Map.fetch!(tasks, &1).id)}
    end)
  end

  defp distances(adjacency, source) do
    if Map.has_key?(adjacency, source) do
      {:ok, bfs(:queue.from_list([{source, 0}]), adjacency, %{source => 0}) |> Map.delete(source)}
    else
      {:ok, %{}}
    end
  end

  defp bfs(queue, adjacency, visited) do
    case :queue.out(queue) do
      {:empty, _} ->
        visited

      {{:value, {id, distance}}, rest} ->
        {next_queue, next_visited} =
          adjacency
          |> Map.fetch!(id)
          |> Enum.reduce({rest, visited}, fn neighbour, {pending, seen} ->
            if Map.has_key?(seen, neighbour) do
              {pending, seen}
            else
              {:queue.in({neighbour, distance + 1}, pending),
               Map.put(seen, neighbour, distance + 1)}
            end
          end)

        bfs(next_queue, adjacency, next_visited)
    end
  end

  defp result_rows(tasks, distances, include?) do
    distances
    |> Enum.flat_map(fn {id, distance} ->
      task = Map.fetch!(tasks, id)

      if include?.(task),
        do: [Map.merge(task, %{distance: distance, direct: distance == 1})],
        else: []
    end)
    |> Enum.sort_by(&{&1.distance, &1.id})
  end

  defp longest_path(%{tasks: tasks}) when map_size(tasks) == 0, do: {:ok, [], 0}

  defp longest_path(graph) do
    indegrees =
      Enum.reduce(graph.forward, Map.new(Map.keys(graph.tasks), &{&1, 0}), fn {_from, successors},
                                                                              acc ->
        Enum.reduce(successors, acc, &Map.update!(&2, &1, fn count -> count + 1 end))
      end)

    roots =
      indegrees
      |> Enum.filter(fn {_id, degree} -> degree == 0 end)
      |> Enum.map(&elem(&1, 0))
      |> sort_ids(graph.tasks)

    best = Map.new(roots, fn id -> {id, {0, [graph.tasks[id].id], [id]}} end)
    {processed, final_best} = topo(roots, indegrees, best, graph, 0)

    if processed != map_size(graph.tasks) do
      {:error, "dependency graph contains a cycle"}
    else
      {_id, {edge_count, _keys, path_ids}} =
        Enum.min_by(final_best, fn {_id, {count, keys, _path}} -> {-count, keys} end)

      {:ok, path_ids, edge_count}
    end
  end

  defp topo([], _indegrees, best, _graph, processed), do: {processed, best}

  defp topo([id | ready], indegrees, best, graph, processed) do
    current = Map.fetch!(best, id)

    {next_degrees, next_best, newly_ready} =
      Enum.reduce(graph.forward[id], {indegrees, best, []}, fn successor,
                                                               {degrees, paths, zeros} ->
        candidate = extend(current, successor, graph.tasks)
        paths = Map.update(paths, successor, candidate, &better(&1, candidate))
        degrees = Map.update!(degrees, successor, &(&1 - 1))
        zeros = if degrees[successor] == 0, do: [successor | zeros], else: zeros
        {degrees, paths, zeros}
      end)

    queue = sort_ids(ready ++ newly_ready, graph.tasks)
    topo(queue, next_degrees, next_best, graph, processed + 1)
  end

  defp extend({count, keys, path}, successor, tasks) do
    {count + 1, keys ++ [tasks[successor].id], path ++ [successor]}
  end

  defp better(existing, candidate) do
    case {existing, candidate} do
      {{old_count, _, _}, {new_count, _, _}} when new_count > old_count ->
        candidate

      {{old_count, _, _}, {new_count, _, _}} when new_count < old_count ->
        existing

      {{_, old_keys, _}, {_, new_keys, _}} ->
        if new_keys < old_keys, do: candidate, else: existing
    end
  end

  defp sort_ids(ids, tasks), do: Enum.sort_by(ids, &Map.fetch!(tasks, &1).id)
  defp uuid!(id), do: Ecto.UUID.dump!(id)
end
