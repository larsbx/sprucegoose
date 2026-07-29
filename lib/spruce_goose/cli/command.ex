defmodule SpruceGoose.CLI.Command do
  @moduledoc false

  def parse(["id"]), do: {:ok, :generate_id}
  def parse(["validate-id", id]), do: {:ok, {:validate_id, id}}

  def parse(["project", "add", key | name]) when name != [],
    do: {:ok, {:add_project, key, Enum.join(name, " ")}}

  def parse(["project", "list"]), do: {:ok, :list_projects}
  def parse(["project", "show", key]), do: {:ok, {:show_project, key}}

  def parse(["roadmap", "add", project, key | name]) when name != [],
    do: {:ok, {:add_roadmap, project, key, Enum.join(name, " ")}}

  def parse(["roadmap", "list" | args]) do
    with {:ok, opts} <- scope_options(args, project: :string) do
      {:ok, {:list_roadmaps, Keyword.get(opts, :project)}}
    end
  end

  def parse(["roadmap", "show", project, key]), do: {:ok, {:show_roadmap, project, key}}

  def parse(["workflow", "list" | args]) do
    with {:ok, opts} <- scope_options(args, project: :string, roadmap: :string) do
      {:ok, {:list_workflows, Keyword.get(opts, :project), Keyword.get(opts, :roadmap)}}
    end
  end

  def parse(["workflow", "show", project, roadmap, workflow_id]),
    do: {:ok, {:show_workflow, project, roadmap, workflow_id}}

  def parse(["workflow", "add" | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [project: :string, roadmap: :string, definition: :string]
      )

    with [] <- invalid,
         {:ok, project} <- required(opts, :project),
         {:ok, roadmap} <- required(opts, :roadmap),
         {:ok, definition} <- required(opts, :definition),
         [workflow_id | name] when name != [] <- rest do
      {:ok, {:add_workflow, project, roadmap, workflow_id, Enum.join(name, " "), definition}}
    else
      {:error, option} -> {:error, "--#{option} is required"}
      _ -> {:error, "invalid workflow add arguments"}
    end
  end

  def parse(["task", "show", id]), do: {:ok, {:show_task, id}}
  def parse(["task", "list"]), do: {:ok, {:list_tasks, nil}}
  def parse(["task", "list", "--state", state]), do: {:ok, {:list_tasks, state}}
  def parse(["task", "propose", id]), do: {:ok, {:transition_task, id, :proposed, nil}}
  def parse(["task", "queue", id]), do: {:ok, {:transition_task, id, :queued, nil}}
  def parse(["task", "ready", id]), do: {:ok, {:transition_task, id, :ready, nil}}
  def parse(["task", "start", id]), do: {:ok, {:transition_task, id, :in_progress, nil}}
  def parse(["task", "done", id]), do: {:ok, {:transition_task, id, :completed, nil}}

  def parse(["task", "cancel", id | reason]) when reason != [],
    do: {:ok, {:transition_task, id, :cancelled, Enum.join(reason, " ")}}

  def parse(["task", "wait", id | reason]) when reason != [],
    do: {:ok, {:transition_task, id, :waiting, Enum.join(reason, " ")}}

  def parse(["task", "link", id, kind, value]),
    do: {:ok, {:link_task, id, kind, value}}

  def parse(["task", "acknowledge-sop", id, sop_path]),
    do: {:ok, {:acknowledge_sop, id, sop_path}}

  def parse(["inbox", "list"]), do: {:ok, :list_inbox}

  def parse(["inbox", "add" | body]) when body != [],
    do: {:ok, {:add_inbox, Enum.join(body, " ")}}

  def parse(["todo", "list", task_id]), do: {:ok, {:list_todos, task_id}}

  def parse(["todo", "add", task_id | body]) when body != [],
    do: {:ok, {:add_todo, task_id, Enum.join(body, " ")}}

  def parse(["todo", "done", task_id, todo_id]),
    do: {:ok, {:complete_todo, task_id, todo_id}}

  def parse(["board", "add", project, roadmap, workflow, key | name]) when name != [],
    do: {:ok, {:add_board, project, roadmap, workflow, key, Enum.join(name, " ")}}

  def parse(["board", "list", project, roadmap, workflow]),
    do: {:ok, {:list_boards, project, roadmap, workflow}}

  def parse(["column", "add", board_id, key, position, state | name]) when name != [],
    do: {:ok, {:add_column, board_id, key, position, state, Enum.join(name, " ")}}

  def parse(["column", "list", board_id]), do: {:ok, {:list_columns, board_id}}

  def parse(["task", "move", task_id, board_id, column_id, rank]),
    do: {:ok, {:move_task, task_id, board_id, column_id, rank}}

  def parse(["task", "metadata", task_id, json]),
    do: {:ok, {:update_task_metadata, task_id, json}}

  def parse(["filter", "add", board_id, name, json]),
    do: {:ok, {:add_filter, board_id, name, json}}

  def parse(["filter", "list", board_id]), do: {:ok, {:list_filters, board_id}}
  def parse(["filter", "apply", filter_id]), do: {:ok, {:apply_filter, filter_id}}

  def parse(["ledger", "import", path]), do: {:ok, {:import_ledger, path}}
  def parse(["ledger", "parity", path]), do: {:ok, {:parity_ledger, path}}

  def parse(["task", "add" | args]) do
    {opts, title, invalid} =
      OptionParser.parse(args,
        strict: [
          project: :string,
          roadmap: :string,
          workflow: :string,
          dod: :string,
          sop: :string,
          type: :string
        ]
      )

    task_type = Keyword.get(opts, :type, "task")

    with [] <- invalid,
         {:ok, project} <- required(opts, :project),
         {:ok, roadmap} <- required(opts, :roadmap),
         {:ok, workflow} <- required(opts, :workflow),
         {:ok, dod} <- required(opts, :dod),
         {:ok, sop_path} <- required(opts, :sop),
         true <- task_type in ["task", "diagnosis"],
         title when title != "" <- Enum.join(title, " ") do
      {:ok,
       {:add_task,
        %{
          project: project,
          roadmap: roadmap,
          workflow: workflow,
          definition_of_done: dod,
          sop_path: sop_path,
          task_type: if(task_type == "diagnosis", do: :diagnosis, else: :task),
          title: title
        }}}
    else
      false -> {:error, "--type must be task or diagnosis"}
      "" -> {:error, "task title is required"}
      {:error, option} -> {:error, "--#{option} is required"}
      _ -> {:error, "invalid task add arguments"}
    end
  end

  def parse(_args), do: {:error, :usage}

  defp scope_options(args, strict) do
    case OptionParser.parse(args, strict: strict) do
      {opts, [], []} -> {:ok, opts}
      _ -> {:error, "invalid list arguments"}
    end
  end

  defp required(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, key}
    end
  end
end
