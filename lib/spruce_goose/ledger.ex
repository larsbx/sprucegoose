defmodule SpruceGoose.Ledger do
  @moduledoc false

  alias SpruceGoose.{Authority, Repo}

  @task_id ~r/^tsk-\d{8}T\d{6}Z-[0-9a-f]{8}$/
  @states %{
    "active" => "in_progress",
    "blocked" => "blocked",
    "cancelled" => "cancelled",
    "done" => "completed",
    "queued" => "queued",
    "waiting" => "waiting"
  }

  def read(path) do
    with {:ok, body} <- File.read(path) do
      body
      |> String.split("\n", trim: true)
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, tasks} ->
        case parse(line) do
          {:ok, task} -> {:cont, {:ok, [task | tasks]}}
          {:error, reason} -> {:halt, {:error, "line #{number}: #{reason}"}}
        end
      end)
      |> then(fn
        {:ok, tasks} -> validate(Enum.reverse(tasks))
        error -> error
      end)
    end
  end

  def parse(line) do
    tokens = String.split(line)

    with {:ok, id} <- required(tokens, "id"),
         true <- Regex.match?(@task_id, id),
         {:ok, project} <- required(tokens, "ref:project"),
         {:ok, roadmap} <- required(tokens, "ref:roadmap"),
         {:ok, workflow} <- required(tokens, "ref:workflow"),
         {:ok, title} <- title(tokens) do
      with {:ok, task_type} <- task_type(tokens),
           {:ok, state} <- task_state(tokens),
           :ok <- schema(tokens) do
        encoded_dod = value(tokens, "dod") || value(tokens, "ref:dod")

        {:ok,
         %{
           id: id,
           project: project,
           roadmap: roadmap,
           workflow: workflow,
           title: title,
           definition_of_done:
             if(encoded_dod,
               do: decode(encoded_dod),
               else: "Grandfathered legacy task: no Definition of Done was recorded"
             ),
           encoded_definition_of_done: encoded_dod,
           task_type: task_type,
           state: state,
           dependencies: values(tokens, "ref:depends-on"),
           raw: line
         }}
      end
    else
      false -> {:error, "invalid task ID"}
      {:error, reason} -> {:error, reason}
    end
  end

  def import(path) do
    with :ok <- Authority.require_tuxedo(),
         {:ok, tasks} <- read(path) do
      Repo.transaction(fn ->
        with :ok <- import_hierarchy(tasks),
             :ok <- import_tasks(tasks),
             :ok <- import_dependencies(tasks) do
          case parity_tasks(tasks) do
            {:ok, _result} = success -> success
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def parity(path) do
    with {:ok, tasks} <- read(path), do: parity_tasks(tasks)
  end

  defp validate(tasks) do
    by_id = Map.new(tasks, &{&1.id, &1})

    cond do
      map_size(by_id) != length(tasks) ->
        {:error, "duplicate task ID"}

      missing =
          Enum.find_value(tasks, fn task ->
            Enum.find(task.dependencies, &(!Map.has_key?(by_id, &1)))
          end) ->
        {:error, "dependency target #{missing} is absent"}

      cross =
          Enum.find_value(tasks, fn task ->
            Enum.find(task.dependencies, fn dependency ->
              by_id[dependency].workflow != task.workflow
            end)
          end) ->
        {:error, "cross-workflow dependency #{cross}"}

      true ->
        {:ok, tasks}
    end
  end

  defp import_hierarchy(tasks) do
    tasks
    |> Enum.group_by(& &1.project)
    |> Enum.each(fn {project, _} ->
      sql!("INSERT INTO projects (key, name) VALUES ($1, $1) ON CONFLICT (key) DO NOTHING", [
        project
      ])
    end)

    tasks
    |> Enum.group_by(&{&1.project, &1.roadmap})
    |> Enum.each(fn {{project, roadmap}, _} ->
      sql!(
        """
        INSERT INTO roadmaps (project_id, key, name)
        SELECT id, $2, $2 FROM projects WHERE key = $1
        ON CONFLICT (project_id, key) DO NOTHING
        """,
        [project, roadmap]
      )
    end)

    tasks
    |> Enum.group_by(&{&1.project, &1.roadmap, &1.workflow})
    |> Enum.each(fn {{project, roadmap, workflow}, _} ->
      sql!(
        """
        INSERT INTO workflows (roadmap_id, workflow_id, name, definition)
        SELECT r.id, $3, $3, $4
        FROM roadmaps r JOIN projects p ON p.id = r.project_id
        WHERE p.key = $1 AND r.key = $2
        ON CONFLICT (roadmap_id, workflow_id) DO NOTHING
        """,
        [
          project,
          roadmap,
          workflow,
          %{
            schema_version: 1,
            tasks: [%{id: "legacy-import", kind: "openclaw", depends_on: [], input: %{}}]
          }
        ]
      )
    end)

    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp import_tasks(tasks) do
    Enum.each(tasks, fn task ->
      result =
        sql!(
          """
          INSERT INTO workflow_tasks
            (workflow_id, task_id, task_type, title, definition_of_done, state, runner, input)
          SELECT w.id, $4, $5, $6, $7, $8, 'openclaw', $9
          FROM workflows w
          JOIN roadmaps r ON r.id = w.roadmap_id
          JOIN projects p ON p.id = r.project_id
          WHERE p.key = $1 AND r.key = $2 AND w.workflow_id = $3
          ON CONFLICT (task_id) DO NOTHING
          """,
          [
            task.project,
            task.roadmap,
            task.workflow,
            task.id,
            task.task_type,
            task.title,
            task.definition_of_done,
            task.state,
            %{
              "legacy_source" => "tuxedo",
              "legacy_raw" => task.raw,
              "legacy_encoded_dod" => task.encoded_definition_of_done
            }
          ]
        )

      if result.num_rows == 0 do
        refresh_imported_task(task)
      end
    end)

    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp import_dependencies(tasks) do
    sql!("DELETE FROM task_dependencies WHERE source = 'tuxedo'")

    Enum.each(tasks, fn task ->
      Enum.each(task.dependencies, fn dependency ->
        sql!(
          """
          INSERT INTO task_dependencies (predecessor_id, successor_id, source)
          SELECT predecessor.id, successor.id, 'tuxedo'
          FROM workflow_tasks predecessor, workflow_tasks successor
          WHERE predecessor.task_id = $1 AND successor.task_id = $2
          ON CONFLICT (predecessor_id, successor_id) DO NOTHING
          """,
          [dependency, task.id]
        )
      end)
    end)

    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp parity_tasks(tasks) do
    rows =
      sql!("""
      SELECT t.task_id, p.key, r.key, w.workflow_id, t.title, t.definition_of_done,
             t.task_type, t.state, t.input->>'legacy_raw', t.input->>'legacy_encoded_dod'
      FROM workflow_tasks t
      JOIN workflows w ON w.id = t.workflow_id
      JOIN roadmaps r ON r.id = w.roadmap_id
      JOIN projects p ON p.id = r.project_id
      ORDER BY t.task_id
      """).rows

    all_actual =
      Map.new(rows, fn [id, project, roadmap, workflow, title, dod, type, state, raw, encoded_dod] ->
        {id, {project, roadmap, workflow, title, dod, type, state, raw, encoded_dod}}
      end)

    expected =
      Map.new(tasks, fn task ->
        {task.id,
         {task.project, task.roadmap, task.workflow, task.title, task.definition_of_done,
          task.task_type, task.state, task.raw, task.encoded_definition_of_done}}
      end)

    actual = Map.take(all_actual, Map.keys(expected))

    dependency_rows =
      sql!("""
      SELECT predecessor.task_id, successor.task_id
      FROM task_dependencies d
      JOIN workflow_tasks predecessor ON predecessor.id = d.predecessor_id
      JOIN workflow_tasks successor ON successor.id = d.successor_id
      WHERE d.source = 'tuxedo'
      """).rows

    expected_dependencies =
      MapSet.new(for task <- tasks, dependency <- task.dependencies, do: {dependency, task.id})

    actual_dependencies =
      dependency_rows
      |> Enum.map(&List.to_tuple/1)
      |> Enum.filter(fn {predecessor, successor} ->
        Map.has_key?(expected, predecessor) and Map.has_key?(expected, successor)
      end)
      |> MapSet.new()

    if actual == expected and actual_dependencies == expected_dependencies do
      {:ok,
       %{
         tasks: map_size(expected),
         dependencies: MapSet.size(expected_dependencies),
         grandfathered_without_dod: Enum.count(tasks, &is_nil(&1.encoded_definition_of_done)),
         parity: true
       }}
    else
      mismatch =
        Enum.find_value(expected, fn {id, value} ->
          if Map.get(actual, id) != value, do: {id, value, Map.get(actual, id)}
        end)

      {:error,
       "ledger parity failed: expected #{map_size(expected)} tasks/#{MapSet.size(expected_dependencies)} dependencies, got #{map_size(actual)}/#{MapSet.size(actual_dependencies)}; mismatch #{inspect(mismatch)}"}
    end
  end

  defp title(tokens) do
    id_index = Enum.find_index(tokens, &String.starts_with?(&1, "id:"))

    tokens
    |> Enum.take(id_index || 0)
    |> Enum.drop_while(&(&1 == "x" or Regex.match?(~r/^\([A-Z]\)$/, &1) or date?(&1)))
    |> Enum.reject(&(String.starts_with?(&1, "+") or String.starts_with?(&1, "@")))
    |> Enum.join(" ")
    |> case do
      "" -> {:error, "task title is missing"}
      value -> {:ok, value}
    end
  end

  defp required(tokens, key) do
    case value(tokens, key) do
      nil -> {:error, "#{key} is missing"}
      value -> {:ok, value}
    end
  end

  defp value(tokens, key), do: values(tokens, key) |> List.first()

  defp values(tokens, key) do
    prefix = key <> ":"

    tokens
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&String.replace_prefix(&1, prefix, ""))
  end

  defp date?(value), do: Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, value)
  defp decode(value), do: String.replace(value, "_", " ")

  defp task_type(tokens) do
    case value(tokens, "type") do
      nil -> {:ok, "task"}
      type when type in ["task", "diagnosis"] -> {:ok, type}
      type -> {:error, "unknown task type #{inspect(type)}"}
    end
  end

  defp task_state(tokens) do
    status = value(tokens, "status") || if(hd(tokens) == "x", do: "done", else: "queued")

    case Map.fetch(@states, status) do
      {:ok, state} -> {:ok, state}
      :error -> {:error, "unknown task status #{inspect(status)}"}
    end
  end

  defp schema(tokens) do
    case value(tokens, "schema") do
      nil -> :ok
      "task-v2" -> :ok
      schema -> {:error, "unknown task schema #{inspect(schema)}"}
    end
  end

  defp refresh_imported_task(task) do
    result =
      sql!(
        """
        UPDATE workflow_tasks AS task SET
          workflow_id = workflow.id,
          task_type = $5,
          title = $6,
        definition_of_done = $7,
        state = $8,
        input = task.input || $9,
        lock_version = task.lock_version + 1,
        updated_at = (now() AT TIME ZONE 'utc')
        FROM workflows AS workflow
        JOIN roadmaps AS roadmap ON roadmap.id = workflow.roadmap_id
        JOIN projects AS project ON project.id = roadmap.project_id
        WHERE task.task_id = $4
          AND task.input->>'legacy_source' = 'tuxedo'
          AND project.key = $1
          AND roadmap.key = $2
          AND workflow.workflow_id = $3
        """,
        [
          task.project,
          task.roadmap,
          task.workflow,
          task.id,
          task.task_type,
          task.title,
          task.definition_of_done,
          task.state,
          %{
            "legacy_source" => "tuxedo",
            "legacy_raw" => task.raw,
            "legacy_encoded_dod" => task.encoded_definition_of_done
          }
        ]
      )

    if result.num_rows != 1 do
      raise "refusing to overwrite non-Tuxedo task #{task.id}"
    end
  end

  defp sql!(statement, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, statement, params)
end
