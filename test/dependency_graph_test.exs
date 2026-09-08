defmodule SpruceGoose.DependencyGraphTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.CLI.Executor
  alias SpruceGoose.Workflows.Graph
  alias SpruceGoose.Workflows.{Definition, Dependency, Project, Roadmap, Task, Workflow}

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

  test "diamond reachability visits each task once at its shortest distance" do
    %{first: first, second: second, third: third, workflow: workflow} =
      graph_fixture("diamond-graph")

    fourth = task!(workflow, "Fourth")

    for {predecessor, successor} <- [
          {first, second},
          {first, third},
          {second, fourth},
          {third, fourth}
        ] do
      assert {:ok, _} =
               Ash.create(Dependency, %{
                 predecessor_id: predecessor.id,
                 successor_id: successor.id
               })
    end

    assert {:ok, %{blockers: blockers}} = Executor.run({:task_blockers, fourth.task_id})
    assert Enum.count(blockers, &(&1.id == first.task_id)) == 1
    assert Enum.find(blockers, &(&1.id == first.task_id)).distance == 2

    assert {:ok, %{impacted: impacted}} = Executor.run({:task_impact, first.task_id})
    assert Enum.count(impacted, &(&1.id == fourth.task_id)) == 1
    assert Enum.find(impacted, &(&1.id == fourth.task_id)).distance == 2
  end

  test "densely layered DAG traversal stays bounded by unique vertices" do
    %{workflow: workflow} = graph_fixture("dense-graph")

    layers =
      for layer <- 1..6 do
        for position <- 1..5 do
          task!(workflow, "Dense #{layer}-#{position}")
        end
      end

    layers
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [predecessors, successors] ->
      for predecessor <- predecessors, successor <- successors do
        assert {:ok, _} =
                 Ash.create(Dependency, %{
                   predecessor_id: predecessor.id,
                   successor_id: successor.id
                 })
      end
    end)

    source = layers |> hd() |> hd()
    assert {:ok, %{impacted: impacted}} = Executor.run({:task_impact, source.task_id})
    assert length(impacted) == 25
    assert Enum.uniq_by(impacted, & &1.id) == impacted

    assert {:ok, %{edge_count: 5, task_count: 6}} =
             Executor.run(
               {:workflow_critical_path, graph_project_key(workflow), graph_roadmap_key(workflow),
                "dense-graph"}
             )
  end

  test "corrupted edge workflow metadata is excluded like the relational authority" do
    fixture = graph_fixture("edge-parity")

    assert {:ok, dependency} =
             Ash.create(Dependency, %{
               predecessor_id: fixture.first.id,
               successor_id: fixture.second.id
             })

    Repo.query!(
      "ALTER TABLE task_dependencies DISABLE TRIGGER task_dependencies_workflow_integrity"
    )

    on_exit(fn ->
      Repo.query!(
        "ALTER TABLE task_dependencies ENABLE TRIGGER task_dependencies_workflow_integrity"
      )
    end)

    other = graph_fixture("edge-parity-other")

    Repo.query!("UPDATE task_dependencies SET workflow_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(other.workflow.id),
      Ecto.UUID.dump!(dependency.id)
    ])

    assert {:ok, %{impacted: []}} = Executor.run({:task_impact, fixture.first.task_id})

    assert %{rows: []} =
             Repo.query!(
               "SELECT successor_id FROM task_dependencies WHERE workflow_id = $1 AND predecessor_id = $2",
               [Ecto.UUID.dump!(fixture.workflow.id), Ecto.UUID.dump!(fixture.first.id)]
             )
  end

  test "critical path resolves equal-length ties by stable task id" do
    fixture = graph_fixture("tie-graph")

    for successor <- [fixture.second, fixture.third] do
      assert {:ok, _} =
               Ash.create(Dependency, %{
                 predecessor_id: fixture.first.id,
                 successor_id: successor.id
               })
    end

    assert {:ok, %{path: path}} =
             Executor.run(
               {:workflow_critical_path, fixture.project_key, fixture.roadmap_key, "tie-graph"}
             )

    expected_successor = Enum.min_by([fixture.second, fixture.third], & &1.task_id)
    assert Enum.map(path, & &1.id) == [fixture.first.task_id, expected_successor.task_id]
  end

  test "critical path returns an empty path for an empty workflow" do
    %{project_key: project_key, roadmap_key: roadmap_key, workflow: workflow} =
      graph_fixture("empty-graph")

    Repo.delete_all(from(task in Task, where: task.workflow_id == ^workflow.id))

    assert {:ok, %{edge_count: 0, task_count: 0, path: []}} =
             Executor.run({:workflow_critical_path, project_key, roadmap_key, "empty-graph"})
  end

  test "blockers omit completed tasks but retain waiting and cancelled tasks" do
    %{first: first, second: second, third: third} = graph_fixture("state-graph")

    for {predecessor, successor} <- [{first, third}, {second, third}] do
      assert {:ok, _} =
               Ash.create(Dependency, %{
                 predecessor_id: predecessor.id,
                 successor_id: successor.id
               })
    end

    Repo.query!("UPDATE workflow_tasks SET state = 'completed' WHERE id = $1", [
      Ecto.UUID.dump!(first.id)
    ])

    Repo.query!("UPDATE workflow_tasks SET state = 'waiting' WHERE id = $1", [
      Ecto.UUID.dump!(second.id)
    ])

    assert {:ok, %{blockers: [%{id: id, state: "waiting"}]}} =
             Executor.run({:task_blockers, third.task_id})

    assert id == second.task_id

    Repo.query!("UPDATE workflow_tasks SET state = 'cancelled' WHERE id = $1", [
      Ecto.UUID.dump!(second.id)
    ])

    assert {:ok, %{blockers: [%{state: "cancelled"}]}} =
             Executor.run({:task_blockers, third.task_id})
  end

  test "all graph commands return errors when the dependency table is unreadable" do
    fixture = graph_fixture("missing-edges")
    Repo.query!("ALTER TABLE task_dependencies RENAME TO task_dependencies_hidden")

    on_exit(fn ->
      Repo.query!("ALTER TABLE task_dependencies_hidden RENAME TO task_dependencies")
    end)

    assert {:error, blocker_error} = Graph.blockers(fixture.third)
    assert {:error, impact_error} = Graph.impact(fixture.first)
    assert {:error, path_error} = Graph.critical_path(fixture.workflow)

    for error <- [blocker_error, impact_error, path_error] do
      assert error =~ "task_dependencies"
    end
  end

  test "corrupted cycles fail bounded critical-path evaluation" do
    fixture = graph_fixture("cycle-guard")

    Repo.query!("ALTER TABLE task_dependencies DISABLE TRIGGER task_dependencies_integrity")

    on_exit(fn ->
      Repo.query!("ALTER TABLE task_dependencies ENABLE TRIGGER task_dependencies_integrity")
    end)

    for {predecessor, successor} <- [
          {fixture.first, fixture.second},
          {fixture.second, fixture.third},
          {fixture.third, fixture.first}
        ] do
      Repo.query!(
        """
        INSERT INTO task_dependencies
          (id, predecessor_id, successor_id, workflow_id, source, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, $3, 'corrupt-fixture', now(), now())
        """,
        [
          Ecto.UUID.dump!(predecessor.id),
          Ecto.UUID.dump!(successor.id),
          Ecto.UUID.dump!(fixture.workflow.id)
        ]
      )
    end

    assert {:error, "dependency graph contains a cycle"} = Graph.critical_path(fixture.workflow)
  end

  defp graph_project_key(workflow) do
    Repo.one!(
      from(project in Project,
        join: roadmap in Roadmap,
        on: roadmap.project_id == project.id,
        where: roadmap.id == ^workflow.roadmap_id,
        select: project.key
      )
    )
  end

  defp graph_roadmap_key(workflow) do
    Repo.one!(
      from(roadmap in Roadmap, where: roadmap.id == ^workflow.roadmap_id, select: roadmap.key)
    )
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
