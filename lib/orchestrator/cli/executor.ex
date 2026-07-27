defmodule Orchestrator.CLI.Executor do
  @moduledoc false

  alias Orchestrator.{Ledger, TaskId}

  alias Orchestrator.Workflows.{
    InboxItem,
    Project,
    Roadmap,
    Task,
    TaskState,
    Todo,
    Workflow
  }

  def run(:generate_id), do: {:ok, %{id: TaskId.generate()}}

  def run({:validate_id, id}) do
    if TaskId.valid?(id), do: {:ok, %{id: id, valid: true}}, else: {:error, "invalid task ID"}
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

  def run({:add_task, input}) do
    with {:ok, project} <- read_one(Project, key: input.project),
         {:ok, roadmap} <- read_one(Roadmap, project_id: project.id, key: input.roadmap),
         {:ok, workflow} <-
           read_one(Workflow, roadmap_id: roadmap.id, workflow_id: input.workflow),
         id = TaskId.generate(),
         {:ok, task} <-
           Ash.create(Task, %{
             workflow_id: workflow.id,
             task_id: id,
             task_type: input.task_type,
             title: input.title,
             definition_of_done: input.definition_of_done,
             runner: :oban
           }) do
      {:ok, task_json(task)}
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
    with {:ok, task} <- Ash.load(task, predecessor_edges: [:predecessor]) do
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

  defp transition(task, target, reason) do
    task
    |> Ash.Changeset.for_update(:transition, %{to_state: target, reason: reason})
    |> Ash.update()
  end

  defp create_or_read_todo(task, todo_id, body) do
    case read_one(Todo, task_id: task.id, todo_id: todo_id) do
      {:ok, todo} ->
        {:ok, todo}

      {:error, "not found"} ->
        with {:ok, todos} <- Ash.read(Ash.Query.filter_input(Todo, task_id: task.id)) do
          Ash.create(Todo, %{
            task_id: task.id,
            todo_id: todo_id,
            body: body,
            position: length(todos) + 1
          })
        end
    end
  end

  defp task_json(task) do
    %{
      id: task.task_id,
      type: task.task_type,
      title: task.title,
      definition_of_done: task.definition_of_done,
      state: task.state,
      workflow_id: task.workflow_id,
      lock_version: task.lock_version,
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

  defp todo_json(todo) do
    %{id: todo.todo_id, body: todo.body, position: todo.position, completed: todo.completed}
  end
end
