defmodule SpruceGoose.CLI.Executor do
  @moduledoc false

  alias SpruceGoose.{Ledger, Repo, SopGate, TaskId}

  alias SpruceGoose.Workflows.{
    Board,
    BoardColumn,
    InboxItem,
    Project,
    Roadmap,
    SavedFilter,
    Task,
    TaskState,
    Todo,
    Workflow
  }

  def run(:generate_id), do: {:ok, %{id: TaskId.generate()}}

  def run({:validate_id, id}) do
    if TaskId.valid?(id), do: {:ok, %{id: id, valid: true}}, else: {:error, "invalid task ID"}
  end

  def run({:add_project, key, name}) do
    with {:ok, project} <- Ash.create(Project, %{key: key, name: name}) do
      {:ok, project_json(project)}
    end
  end

  def run(:list_projects) do
    with {:ok, projects} <- Ash.read(Project) do
      {:ok, %{projects: projects |> Enum.sort_by(& &1.key) |> Enum.map(&project_json/1)}}
    end
  end

  def run({:show_project, key}) do
    with {:ok, project} <- read_one(Project, key: key) do
      {:ok, project_json(project)}
    end
  end

  def run({:list_roadmaps, project_key}) do
    with {:ok, filter} <- roadmap_scope(project_key),
         {:ok, roadmaps} <- Ash.read(Ash.Query.filter_input(Roadmap, filter)),
         {:ok, projects} <- Ash.read(Project) do
      keys = Map.new(projects, &{&1.id, &1.key})

      {:ok,
       %{
         roadmaps:
           roadmaps
           |> Enum.sort_by(&{Map.get(keys, &1.project_id), &1.key})
           |> Enum.map(&Map.put(roadmap_json(&1), :project, Map.get(keys, &1.project_id)))
       }}
    end
  end

  def run({:show_roadmap, project_key, key}) do
    with {:ok, project} <- read_one(Project, key: project_key),
         {:ok, roadmap} <- read_one(Roadmap, project_id: project.id, key: key) do
      {:ok, Map.put(roadmap_json(roadmap), :project, project.key)}
    end
  end

  def run({:list_workflows, project_key, roadmap_key}) do
    with {:ok, roadmap_ids} <- workflow_scope(project_key, roadmap_key),
         filter = if(roadmap_ids, do: [roadmap_id: [in: roadmap_ids]], else: []),
         {:ok, workflows} <- Ash.read(Ash.Query.filter_input(Workflow, filter)),
         {:ok, labels} <- roadmap_labels() do
      {:ok,
       %{
         workflows:
           workflows
           |> Enum.sort_by(&{Map.get(labels, &1.roadmap_id), &1.workflow_id})
           |> Enum.map(fn workflow ->
             %{
               id: workflow.id,
               roadmap_id: workflow.roadmap_id,
               roadmap: Map.get(labels, workflow.roadmap_id),
               workflow_id: workflow.workflow_id,
               name: workflow.name
             }
           end)
       }}
    end
  end

  def run({:show_workflow, project_key, roadmap_key, workflow_key}) do
    with {:ok, project} <- read_one(Project, key: project_key),
         {:ok, roadmap} <- read_one(Roadmap, project_id: project.id, key: roadmap_key),
         {:ok, workflow} <-
           read_one(Workflow, roadmap_id: roadmap.id, workflow_id: workflow_key) do
      {:ok,
       workflow_json(workflow)
       |> Map.put(:project, project.key)
       |> Map.put(:roadmap, roadmap.key)}
    end
  end

  def run({:add_roadmap, project_key, key, name}) do
    with {:ok, project} <- read_one(Project, key: project_key),
         {:ok, roadmap} <-
           Ash.create(Roadmap, %{project_id: project.id, key: key, name: name}) do
      {:ok, roadmap_json(roadmap)}
    end
  end

  def run({:add_workflow, project_key, roadmap_key, workflow_id, name, definition_json}) do
    with {:ok, project} <- read_one(Project, key: project_key),
         {:ok, roadmap} <- read_one(Roadmap, project_id: project.id, key: roadmap_key),
         {:ok, definition_input} <- decode_json_object(definition_json),
         {:ok, definition} <- SpruceGoose.Workflows.Definition.parse(definition_input),
         {:ok, workflow} <-
           Ash.create(Workflow, %{
             roadmap_id: roadmap.id,
             workflow_id: workflow_id,
             name: name,
             definition: definition
           }) do
      {:ok, workflow_json(workflow)}
    end
  end

  def run({:import_ledger, path}), do: Ledger.import(path)
  def run({:parity_ledger, path}), do: Ledger.parity(path)

  def run({:show_task, id}) do
    with :ok <- require_valid_id(id),
         {:ok, task} <- read_one(Task, task_id: id) do
      {:ok, task_json(task)}
    end
  end

  def run({:list_tasks, state}) do
    with {:ok, state} <- optional_state(state),
         query = if(state, do: Ash.Query.filter_input(Task, state: state), else: Task),
         {:ok, tasks} <- Ash.read(query) do
      {:ok, %{tasks: tasks |> Enum.sort_by(& &1.task_id) |> Enum.map(&task_json/1)}}
    end
  end

  def run({:transition_task, id, target, reason}) do
    with :ok <- require_valid_id(id),
         {:ok, task} <- read_one(Task, task_id: id),
         :ok <- require_transition_preconditions(task, target),
         {:ok, task} <- transition(task, target, reason) do
      {:ok, task_json(task)}
    end
  end

  def run({:link_task, id, kind, value}) do
    with :ok <- require_valid_id(id),
         {:ok, task} <- read_one(Task, task_id: id),
         references = Map.get(task.input, "references", []),
         input =
           Map.put(task.input, "references", references ++ [%{"kind" => kind, "value" => value}]),
         {:ok, task} <- task |> Ash.Changeset.for_update(:revise, %{input: input}) |> Ash.update() do
      {:ok, task_json(task)}
    end
  end

  def run({:acknowledge_sop, id, sop_path}) do
    with :ok <- require_valid_id(id),
         {:ok, task} <- read_one(Task, task_id: id),
         :ok <- sop_acknowledgment_allowed(task),
         true <- sop_path == SopGate.path(),
         {:ok, task} <-
           task
           |> Ash.Changeset.for_update(:acknowledge_sop, %{})
           |> Ash.update() do
      {:ok, task_json(task)}
    else
      false -> {:error, "SOP path must be #{SopGate.path()}"}
      result -> result
    end
  end

  def run({:add_inbox, body}) do
    capture_id = "inbox-" <> (:crypto.hash(:sha256, body) |> Base.encode16(case: :lower))

    with {:ok, item} <- Ash.create(InboxItem, %{capture_id: capture_id, body: body}) do
      {:ok, inbox_json(item)}
    end
  end

  def run(:list_inbox) do
    with {:ok, items} <- Ash.read(InboxItem) do
      {:ok, %{items: items |> Enum.sort_by(& &1.capture_id) |> Enum.map(&inbox_json/1)}}
    end
  end

  def run({:list_todos, task_id}) do
    with :ok <- require_valid_id(task_id),
         {:ok, task} <- read_one(Task, task_id: task_id),
         {:ok, todos} <- Ash.read(Ash.Query.filter_input(Todo, task_id: task.id)) do
      {:ok, %{todos: todos |> Enum.sort_by(& &1.position) |> Enum.map(&todo_json/1)}}
    end
  end

  def run({:add_todo, task_id, body}) do
    with :ok <- require_valid_id(task_id),
         {:ok, task} <- read_one(Task, task_id: task_id),
         todo_id = "todo-" <> (:crypto.hash(:sha256, body) |> Base.encode16(case: :lower)),
         {:ok, todo} <- create_or_read_todo(task, todo_id, body) do
      {:ok, todo_json(todo)}
    end
  end

  def run({:complete_todo, task_id, todo_id}) do
    with :ok <- require_valid_id(task_id),
         {:ok, task} <- read_one(Task, task_id: task_id),
         {:ok, todo} <- read_one(Todo, task_id: task.id, todo_id: todo_id),
         {:ok, todo} <- todo |> Ash.Changeset.for_update(:complete) |> Ash.update() do
      {:ok, todo_json(todo)}
    end
  end

  def run({:add_board, project_key, roadmap_key, workflow_key, key, name}) do
    with {:ok, project} <- read_one(Project, key: project_key),
         {:ok, roadmap} <- read_one(Roadmap, project_id: project.id, key: roadmap_key),
         {:ok, workflow} <-
           read_one(Workflow, roadmap_id: roadmap.id, workflow_id: workflow_key),
         {:ok, board} <-
           Ash.create(Board, %{workflow_id: workflow.id, key: key, name: name}) do
      {:ok, board_json(board)}
    end
  end

  def run({:list_boards, project_key, roadmap_key, workflow_key}) do
    with {:ok, project} <- read_one(Project, key: project_key),
         {:ok, roadmap} <- read_one(Roadmap, project_id: project.id, key: roadmap_key),
         {:ok, workflow} <-
           read_one(Workflow, roadmap_id: roadmap.id, workflow_id: workflow_key),
         {:ok, boards} <- Ash.read(Ash.Query.filter_input(Board, workflow_id: workflow.id)) do
      {:ok, %{boards: Enum.map(boards, &board_json/1)}}
    end
  end

  def run({:add_column, board_id, key, position, state, name}) do
    with {position, ""} <- Integer.parse(position),
         {:ok, state} <- optional_state(state),
         {:ok, column} <-
           Ash.create(BoardColumn, %{
             board_id: board_id,
             key: key,
             name: name,
             position: position,
             task_state: state
           }) do
      {:ok, column_json(column)}
    else
      :error -> {:error, "position must be an integer"}
      error -> error
    end
  end

  def run({:list_columns, board_id}) do
    with {:ok, columns} <- Ash.read(Ash.Query.filter_input(BoardColumn, board_id: board_id)) do
      {:ok, %{columns: columns |> Enum.sort_by(& &1.position) |> Enum.map(&column_json/1)}}
    end
  end

  def run({:move_task, task_id, board_id, column_id, rank}) do
    with :ok <- require_valid_id(task_id),
         {:ok, task} <- read_one(Task, task_id: task_id),
         {:ok, column} <- read_one(BoardColumn, id: column_id, board_id: board_id),
         {:ok, task} <-
           Ash.update(
             task,
             %{board_id: board_id, column_id: column_id, rank: rank, to_state: column.task_state},
             action: :move
           ) do
      {:ok, task_json(task)}
    end
  end

  def run({:update_task_metadata, task_id, json}) do
    with :ok <- require_valid_id(task_id),
         {:ok, input} <- decode_metadata(json),
         {:ok, task} <- read_one(Task, task_id: task_id),
         {:ok, task} <- Ash.update(task, input, action: :update_board_metadata) do
      {:ok, task_json(task)}
    end
  end

  def run({:add_filter, board_id, name, json}) do
    with {:ok, criteria} <- decode_json_object(json),
         {:ok, filter} <-
           Ash.create(SavedFilter, %{board_id: board_id, name: name, criteria: criteria}) do
      {:ok, filter_json(filter)}
    end
  end

  def run({:list_filters, board_id}) do
    with {:ok, filters} <- Ash.read(Ash.Query.filter_input(SavedFilter, board_id: board_id)) do
      {:ok, %{filters: Enum.map(filters, &filter_json/1)}}
    end
  end

  def run({:apply_filter, filter_id}) do
    with {:ok, filter} <- read_one(SavedFilter, id: filter_id),
         {:ok, tasks} <- Ash.read(Ash.Query.filter_input(Task, board_id: filter.board_id)) do
      {:ok,
       %{
         tasks:
           tasks |> Enum.filter(&matches_filter?(&1, filter.criteria)) |> Enum.map(&task_json/1)
       }}
    end
  end

  def run({:add_task, input}) do
    with {:ok, project} <- read_one(Project, key: input.project),
         {:ok, roadmap} <- read_one(Roadmap, project_id: project.id, key: input.roadmap),
         {:ok, workflow} <-
           read_one(Workflow, roadmap_id: roadmap.id, workflow_id: input.workflow),
         true <- input.sop_path == SopGate.path(),
         id = TaskId.generate(),
         {:ok, task} <-
           Ash.create(
             Task,
             %{
               workflow_id: workflow.id,
               task_id: id,
               task_type: input.task_type,
               title: input.title,
               definition_of_done: input.definition_of_done,
               runner: :oban
             }
           ) do
      {:ok, task_json(task)}
    else
      false -> {:error, "SOP path must be #{SopGate.path()}"}
      result -> result
    end
  end

  defp roadmap_scope(nil), do: {:ok, []}

  defp roadmap_scope(project_key) do
    with {:ok, project} <- read_one(Project, key: project_key) do
      {:ok, [project_id: project.id]}
    end
  end

  defp workflow_scope(nil, nil), do: {:ok, nil}

  defp workflow_scope(nil, roadmap_key) do
    with {:ok, roadmaps} <- Ash.read(Ash.Query.filter_input(Roadmap, key: roadmap_key)) do
      case roadmaps do
        [] -> {:error, "not found"}
        roadmaps -> {:ok, Enum.map(roadmaps, & &1.id)}
      end
    end
  end

  defp workflow_scope(project_key, roadmap_key) do
    with {:ok, project} <- read_one(Project, key: project_key) do
      filter =
        if roadmap_key,
          do: [project_id: project.id, key: roadmap_key],
          else: [project_id: project.id]

      with {:ok, roadmaps} <- Ash.read(Ash.Query.filter_input(Roadmap, filter)) do
        case roadmaps do
          [] -> {:error, "not found"}
          roadmaps -> {:ok, Enum.map(roadmaps, & &1.id)}
        end
      end
    end
  end

  defp roadmap_labels do
    with {:ok, projects} <- Ash.read(Project),
         {:ok, roadmaps} <- Ash.read(Roadmap) do
      project_keys = Map.new(projects, &{&1.id, &1.key})

      {:ok,
       Map.new(roadmaps, fn roadmap ->
         {roadmap.id, "#{Map.get(project_keys, roadmap.project_id)}/#{roadmap.key}"}
       end)}
    end
  end

  defp read_one(resource, filter) do
    case resource |> Ash.Query.filter_input(filter) |> Ash.read_one() do
      {:ok, nil} -> {:error, "not found"}
      result -> result
    end
  end

  defp require_valid_id(id) do
    if TaskId.valid?(id), do: :ok, else: {:error, "invalid task ID"}
  end

  defp optional_state(nil), do: {:ok, nil}

  defp optional_state(state) do
    case Ash.Type.cast_input(TaskState, state) do
      {:ok, state} -> {:ok, state}
      _ -> {:error, "invalid task state"}
    end
  end

  defp require_transition_preconditions(%{state: :ready} = task, :in_progress) do
    with :ok <- SopGate.verify(task),
         {:ok, task} <- Ash.load(task, predecessor_edges: [:predecessor]) do
      if Enum.all?(task.predecessor_edges, &(&1.predecessor.state == :completed)) do
        :ok
      else
        {:error, "task has incomplete predecessors"}
      end
    end
  end

  defp require_transition_preconditions(_task, :in_progress),
    do: {:error, "task must be ready"}

  defp require_transition_preconditions(_task, _target), do: :ok

  defp sop_acknowledgment_allowed(%{state: state}) when state in [:completed, :cancelled],
    do: {:error, "cannot acknowledge SOP on terminal task"}

  defp sop_acknowledgment_allowed(_task), do: :ok

  defp transition(task, target, reason) do
    task
    |> Ash.Changeset.for_update(:transition, %{to_state: target, reason: reason})
    |> Ash.update()
  end

  defp create_or_read_todo(task, todo_id, body) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [task.id])

      with {:ok, fresh_task} <- read_one(Task, id: task.id),
           :ok <- todo_admission_allowed(fresh_task),
           result <- read_one(Todo, task_id: task.id, todo_id: todo_id) do
        case result do
          {:ok, todo} ->
            {:ok, todo}

          {:error, "not found"} ->
            with {:ok, todos} <- Ash.read(Ash.Query.filter_input(Todo, task_id: task.id)) do
              Ash.create(
                Todo,
                %{
                  task_id: task.id,
                  todo_id: todo_id,
                  body: body,
                  position: length(todos) + 1
                },
                return_notifications?: true
              )
            end
        end
      end
    end)
    |> case do
      {:ok, {:ok, todo, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, todo}

      {:ok, result} ->
        result

      {:error, error} ->
        {:error, error}
    end
  end

  defp todo_admission_allowed(%{state: state}) when state in [:completed, :cancelled],
    do: {:error, "cannot add TODO to terminal task"}

  defp todo_admission_allowed(_task), do: :ok

  defp task_json(task) do
    %{
      id: task.task_id,
      type: task.task_type,
      title: task.title,
      description: task.description,
      definition_of_done: task.definition_of_done,
      sop_gate_required: task.sop_gate_required,
      sop_id: task.sop_id,
      sop_path: task.sop_path,
      sop_digest: task.sop_digest,
      sop_acknowledged_at: task.sop_acknowledged_at,
      state: task.state,
      workflow_id: task.workflow_id,
      lock_version: task.lock_version,
      board_id: task.board_id,
      column_id: task.column_id,
      rank: task.rank,
      priority: task.priority,
      due_at: task.due_at,
      assignees: task.assignees,
      labels: task.labels,
      custom_fields: task.custom_fields,
      board_revision: task.board_revision,
      references: Map.get(task.input, "references", []),
      wait_reason: Map.get(task.input, "wait_reason"),
      cancel_reason: Map.get(task.input, "cancel_reason"),
      import_provenance:
        if(Map.get(task.input, "legacy_source"),
          do: %{
            source: Map.get(task.input, "legacy_source"),
            raw: Map.get(task.input, "legacy_raw"),
            encoded_definition_of_done: Map.get(task.input, "legacy_encoded_dod")
          }
        )
    }
  end

  defp inbox_json(item), do: %{id: item.capture_id, body: item.body, state: item.state}

  defp project_json(project), do: %{id: project.id, key: project.key, name: project.name}

  defp roadmap_json(roadmap),
    do: %{id: roadmap.id, project_id: roadmap.project_id, key: roadmap.key, name: roadmap.name}

  defp workflow_json(workflow) do
    %{
      id: workflow.id,
      roadmap_id: workflow.roadmap_id,
      workflow_id: workflow.workflow_id,
      name: workflow.name,
      definition: %{
        schema_version: workflow.definition.schema_version,
        tasks:
          Enum.map(workflow.definition.tasks, fn task ->
            %{
              id: task.id,
              kind: task.kind,
              depends_on: task.depends_on,
              input: task.input
            }
          end)
      }
    }
  end

  defp board_json(board),
    do: %{id: board.id, workflow_id: board.workflow_id, key: board.key, name: board.name}

  defp column_json(column),
    do: %{
      id: column.id,
      board_id: column.board_id,
      key: column.key,
      name: column.name,
      position: column.position,
      state: column.task_state
    }

  defp filter_json(filter),
    do: %{id: filter.id, board_id: filter.board_id, name: filter.name, criteria: filter.criteria}

  defp todo_json(todo) do
    %{id: todo.todo_id, body: todo.body, position: todo.position, completed: todo.completed}
  end

  @metadata_keys ~w(board_id column_id rank priority due_at assignees labels custom_fields)
  defp decode_metadata(json) do
    with {:ok, input} <- decode_json_object(json),
         [] <- Map.keys(input) -- @metadata_keys do
      {:ok, Map.new(input, fn {key, value} -> {String.to_existing_atom(key), value} end)}
    else
      [_ | _] -> {:error, "metadata contains unsupported keys"}
      error -> error
    end
  end

  defp decode_json_object(json) do
    case Jason.decode(json) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, "expected a JSON object"}
    end
  end

  defp matches_filter?(task, criteria) do
    Enum.all?(criteria, fn
      {"assignee", value} -> value in task.assignees
      {"column", value} -> value == task.column_id
      {"label", value} -> value in task.labels
      {"priority", value} -> value == task.priority
      {"state", values} when is_list(values) -> to_string(task.state) in values
      {"state", value} -> to_string(task.state) == value
      {"text", value} -> String.contains?(String.downcase(task.title), String.downcase(value))
    end)
  end
end
