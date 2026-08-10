defmodule SpruceGoose.Workflows.Graph do
  @moduledoc """
  Read-only PostgreSQL 19 property-graph queries over workflow task dependencies.

  Relational task and dependency rows remain authoritative. Callers must first
  authorize the subject task or workflow through `SpruceGoose.Authz`; every SQL
  query is then constrained to that authorized workflow UUID.

  PostgreSQL 19 beta 2 supports fixed-length SQL/PGQ patterns but not
  variable-length patterns. `GRAPH_TABLE` supplies the authorized edge set and
  recursive SQL computes transitive reachability and the longest DAG path.
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
    COLUMNS (
      predecessor.id AS predecessor_id,
      successor.id AS successor_id
    )
  )
  """

  @doc "Incomplete direct and transitive predecessors of an authorized task."
  def blockers(%Task{} = task) do
    sql = """
    WITH RECURSIVE edge_rows AS MATERIALIZED (#{@edge_rows}),
    paths(id, distance) AS (
      SELECT predecessor_id, 1
      FROM edge_rows
      WHERE successor_id = $2::uuid
      UNION ALL
      SELECT edge_rows.predecessor_id, paths.distance + 1
      FROM paths
      JOIN edge_rows ON edge_rows.successor_id = paths.id
    ),
    closest AS (
      SELECT id, min(distance) AS distance
      FROM paths
      GROUP BY id
    )
    SELECT task.task_id, task.title, task.state, closest.distance
    FROM closest
    JOIN workflow_tasks AS task ON task.id = closest.id
    WHERE task.workflow_id = $1::uuid
      AND task.state <> 'completed'
    ORDER BY closest.distance, task.task_id
    """

    {:ok, rows(sql, task)}
  end

  @doc "Direct and transitive successors affected by an authorized task."
  def impact(%Task{} = task) do
    sql = """
    WITH RECURSIVE edge_rows AS MATERIALIZED (#{@edge_rows}),
    paths(id, distance) AS (
      SELECT successor_id, 1
      FROM edge_rows
      WHERE predecessor_id = $2::uuid
      UNION ALL
      SELECT edge_rows.successor_id, paths.distance + 1
      FROM paths
      JOIN edge_rows ON edge_rows.predecessor_id = paths.id
    ),
    closest AS (
      SELECT id, min(distance) AS distance
      FROM paths
      GROUP BY id
    )
    SELECT task.task_id, task.title, task.state, closest.distance
    FROM closest
    JOIN workflow_tasks AS task ON task.id = closest.id
    WHERE task.workflow_id = $1::uuid
    ORDER BY closest.distance, task.task_id
    """

    {:ok, rows(sql, task)}
  end

  @doc "The deterministic longest dependency path in an authorized workflow."
  def critical_path(%Workflow{} = workflow) do
    sql = """
    WITH RECURSIVE edge_rows AS MATERIALIZED (#{@edge_rows}),
    paths(id, path_ids, path_keys, edge_count) AS (
      SELECT task.id, ARRAY[task.id], ARRAY[task.task_id], 0
      FROM workflow_tasks AS task
      WHERE task.workflow_id = $1::uuid
        AND NOT EXISTS (
          SELECT 1 FROM edge_rows WHERE edge_rows.successor_id = task.id
        )
      UNION ALL
      SELECT edge_rows.successor_id,
             paths.path_ids || edge_rows.successor_id,
             paths.path_keys || successor.task_id,
             paths.edge_count + 1
      FROM paths
      JOIN edge_rows ON edge_rows.predecessor_id = paths.id
      JOIN workflow_tasks AS successor ON successor.id = edge_rows.successor_id
    )
    SELECT path_ids, edge_count
    FROM paths
    ORDER BY edge_count DESC, path_keys ASC
    LIMIT 1
    """

    # AUTHORIZATION: the CLI authorized `workflow` through Ash before entering
    # this module; the bound workflow UUID is the complete SQL scope.
    case Repo.query!(sql, [uuid!(workflow.id)]).rows do
      [] -> {:ok, %{edge_count: 0, task_count: 0, path: []}}
      [[path_ids, edge_count]] -> {:ok, path_result(path_ids, edge_count, workflow.id)}
    end
  rescue
    error in Postgrex.Error -> {:error, Exception.message(error)}
  end

  defp rows(sql, %Task{} = task) do
    # AUTHORIZATION: the CLI authorized `task` through Ash before entering this
    # module; both its workflow UUID and row UUID are bound into the query.
    Repo.query!(sql, [uuid!(task.workflow_id), uuid!(task.id)]).rows
    |> Enum.map(fn [id, title, state, distance] ->
      %{id: id, title: title, state: state, distance: distance, direct: distance == 1}
    end)
  end

  defp path_result(path_ids, edge_count, workflow_id) do
    # AUTHORIZATION: path IDs came only from the already scoped edge set.
    rows =
      Repo.query!(
        """
        SELECT task.id, task.task_id, task.title, task.state
        FROM unnest($1::uuid[]) WITH ORDINALITY AS path(id, position)
        JOIN workflow_tasks AS task ON task.id = path.id
        WHERE task.workflow_id = $2::uuid
        ORDER BY path.position
        """,
        [path_ids, uuid!(workflow_id)]
      ).rows

    path =
      Enum.map(rows, fn [_id, task_id, title, state] ->
        %{id: task_id, title: title, state: state}
      end)

    %{edge_count: edge_count, task_count: length(path), path: path}
  end

  defp uuid!(id), do: Ecto.UUID.dump!(id)
end
