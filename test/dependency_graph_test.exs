defmodule SpruceGoose.DependencyGraphTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Workflows.{Definition, Dependency, Project, Roadmap, Task, Workflow}

  test "the PostgreSQL property graph exposes task dependency edges" do
    %{workflow: workflow, first: first, second: second} = graph_fixture("native-graph")

    assert {:ok, _edge} =
             Ash.create(Dependency, %{
               predecessor_id: first.id,
               successor_id: second.id,
               source: "native"
             })

    assert %{rows: [[from_id, to_id]]} =
             Repo.query!(
               """
               SELECT predecessor_task_id, successor_task_id
               FROM GRAPH_TABLE (
                 sprucegoose_task_dependency_graph
                 MATCH (predecessor IS task)-[dependency IS dependency]->(successor IS task)
                 WHERE predecessor.workflow_id = $1 AND successor.workflow_id = $1
                 COLUMNS (
                   predecessor.task_id AS predecessor_task_id,
                   successor.task_id AS successor_task_id
                 )
               )
               """,
               [Ecto.UUID.dump!(workflow.id)]
             )

    assert {from_id, to_id} == {first.task_id, second.task_id}
  end

  test "blockers and impact traverse the workflow DAG with deterministic distances" do
    %{first: first, second: second, third: third} = graph_fixture("query-graph")

    for {predecessor, successor} <- [{first, second}, {second, third}] do
      assert {:ok, _edge} =
               Ash.create(Dependency, %{
                 predecessor_id: predecessor.id,
                 successor_id: successor.id,
                 source: "native"
               })
    end

    assert {:ok, %{task: third_id, blockers: blockers}} =
             Executor.run({:task_blockers, third.task_id})

    assert third_id == third.task_id

    assert Enum.map(blockers, &{&1.id, &1.distance, &1.direct}) == [
             {second.task_id, 1, true},
             {first.task_id, 2, false}
           ]

    assert {:ok, %{task: first_id, impacted: impacted}} =
             Executor.run({:task_impact, first.task_id})

    assert first_id == first.task_id

    assert Enum.map(impacted, &{&1.id, &1.distance, &1.direct}) == [
             {second.task_id, 1, true},
             {third.task_id, 2, false}
           ]
  end

  test "critical path returns the longest deterministic path in one workflow" do
    %{
      project_key: project_key,
      roadmap_key: roadmap_key,
      first: first,
      second: second,
      third: third
    } = graph_fixture("critical-graph")

    for {predecessor, successor} <- [{first, second}, {second, third}] do
      assert {:ok, _edge} =
               Ash.create(Dependency, %{
                 predecessor_id: predecessor.id,
                 successor_id: successor.id,
                 source: "native"
               })
    end

    assert {:ok, %{edge_count: 2, task_count: 3, path: path}} =
             Executor.run({:workflow_critical_path, project_key, roadmap_key, "critical-graph"})

    assert Enum.map(path, & &1.id) == [first.task_id, second.task_id, third.task_id]
  end

  test "graph blockers match the incumbent recursive relational query" do
    %{first: first, second: second, third: third, workflow: workflow} =
      graph_fixture("parity-graph")

    for {predecessor, successor} <- [{first, second}, {second, third}] do
      assert {:ok, _edge} =
               Ash.create(Dependency, %{
                 predecessor_id: predecessor.id,
                 successor_id: successor.id,
                 source: "native"
               })
    end

    assert {:ok, %{blockers: blockers}} = Executor.run({:task_blockers, third.task_id})

    relational =
      Repo.query!(
        """
        WITH RECURSIVE predecessors(id, distance) AS (
          SELECT predecessor_id, 1
          FROM task_dependencies
          WHERE workflow_id = $1 AND successor_id = $2
          UNION ALL
          SELECT dependency.predecessor_id, predecessors.distance + 1
          FROM predecessors
          JOIN task_dependencies AS dependency
            ON dependency.successor_id = predecessors.id
           AND dependency.workflow_id = $1
        )
        SELECT task.task_id, min(predecessors.distance)
        FROM predecessors
        JOIN workflow_tasks AS task ON task.id = predecessors.id
        WHERE task.state <> 'completed'
        GROUP BY task.task_id
        ORDER BY min(predecessors.distance), task.task_id
        """,
        [Ecto.UUID.dump!(workflow.id), Ecto.UUID.dump!(third.id)]
      ).rows

    assert Enum.map(blockers, &{&1.id, &1.distance}) == Enum.map(relational, &List.to_tuple/1)
  end

  defp graph_fixture(workflow_key) do
    suffix = System.unique_integer([:positive])
    project_key = "graph-project-#{suffix}"
    roadmap_key = "graph-map-#{suffix}"

    {:ok, definition} =
      Definition.parse(%{
        tasks: [
          %{id: "first", kind: :oban},
          %{id: "second", kind: :oban, depends_on: ["first"]},
          %{id: "third", kind: :oban, depends_on: ["second"]}
        ]
      })

    {:ok, project} = Ash.create(Project, %{key: project_key, name: "Graph project"})

    {:ok, roadmap} =
      Ash.create(Roadmap, %{project_id: project.id, key: roadmap_key, name: "Graph map"})

    {:ok, workflow} =
      Ash.create(Workflow, %{
        roadmap_id: roadmap.id,
        workflow_id: workflow_key,
        name: "Graph workflow",
        definition: definition
      })

    first = task!(workflow, "First")
    second = task!(workflow, "Second")
    third = task!(workflow, "Third")

    %{
      project: project,
      roadmap: roadmap,
      workflow: workflow,
      project_key: project_key,
      roadmap_key: roadmap_key,
      first: first,
      second: second,
      third: third
    }
  end

  defp task!(workflow, title) do
    {:ok, task} =
      Ash.create(Task, %{
        task_id: SpruceGoose.TaskId.generate(),
        workflow_id: workflow.id,
        task_type: :task,
        title: title,
        definition_of_done: "Graph query returns the expected path",
        runner: :oban,
        priority: 2
      })

    task
  end
end
