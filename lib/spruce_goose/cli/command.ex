defmodule SpruceGoose.CLI.Command do
  @moduledoc false

  # Grouped by noun, in the order a caller discovers them: look things up,
  # admit work, move it, attach evidence. Kept adjacent to the parse/1 clauses
  # so drift is visible in one screen rather than across two files.
  @usage [
    {"id", ["id", "validate-id ID"]},
    {"project", ["add KEY NAME", "list", "show KEY", "rename KEY NAME", "remove KEY"]},
    {"roadmap",
     [
       "add PROJECT KEY NAME",
       "list [--project KEY]",
       "show PROJECT KEY",
       "rename PROJECT KEY NAME",
       "remove PROJECT KEY"
     ]},
    {"workflow",
     [
       "add --project KEY --roadmap KEY --definition JSON ID NAME",
       "list [--project KEY] [--roadmap KEY]",
       "show PROJECT ROADMAP ID",
       "rename PROJECT ROADMAP ID NAME",
       "remove PROJECT ROADMAP ID"
     ]},
    {"task",
     [
       "add --project KEY --roadmap KEY --workflow ID --priority N --dod TEXT --sop PATH [--type task|diagnosis] [--artifact NAME] TITLE",
       "list [--state S] [--project KEY] [--roadmap KEY] [--workflow ID] [--type T] [--label L] [--assignee A] [--priority N] [--text T]",
       "show ID",
       "propose|queue|ready|start|done ID",
       "wait ID REASON",
       "cancel ID REASON",
       "link ID KIND VALUE",
       "link ID --remove KIND VALUE",
       "acknowledge-sop ID PATH",
       "artifact-receipt ID JSON",
       "move ID BOARD COLUMN RANK",
       "metadata ID JSON"
     ]},
    {"dep",
     [
       "add TASK_ID --after PREDECESSOR_ID",
       "remove TASK_ID --after PREDECESSOR_ID",
       "list TASK_ID"
     ]},
    {"todo",
     [
       "add TASK_ID BODY",
       "list TASK_ID",
       "done TASK_ID TODO_ID",
       "remove TASK_ID TODO_ID",
       "dep add TASK_ID TODO_ID --after PREDECESSOR_ID",
       "dep remove TASK_ID TODO_ID --after PREDECESSOR_ID",
       "dep list TASK_ID"
     ]},
    {"board",
     [
       "add PROJECT ROADMAP WORKFLOW KEY NAME",
       "list PROJECT ROADMAP WORKFLOW",
       "rename BOARD NAME",
       "remove BOARD"
     ]},
    {"column",
     ["add BOARD KEY POSITION STATE NAME", "list BOARD", "rename COLUMN NAME", "remove COLUMN"]},
    {"filter", ["add BOARD NAME JSON", "list BOARD", "apply FILTER", "remove FILTER"]},
    {"inbox",
     [
       "add TEXT",
       "list [--state pending|resolved|dropped|all]",
       "done CAPTURE_ID",
       "drop CAPTURE_ID REASON",
       "promote CAPTURE_ID --project KEY --roadmap KEY --workflow ID --priority N --dod TEXT --sop PATH [--title T]"
     ]},
    {"revise",
     [
       "propose --file ABSOLUTE_PATH",
       "list [--state pending|applied|withdrawn|all] [--target REF]",
       "show REVISION",
       "approve REVISION --task TASK_ID --digest SHA256 [--self]",
       "withdraw REVISION REASON"
     ]},
    {"actor",
     [
       "add NAME --kind human|agent [--description TEXT]",
       "list [--kind human|agent|system]",
       "show NAME",
       "disable NAME REASON",
       "enable NAME"
     ]},
    {"grant",
     [
       "add NAME --role ROLE --scope '*'|project:KEY",
       "list [--actor NAME] [--role ROLE]",
       "remove NAME --role ROLE --scope SCOPE"
     ]},
    {"ledger", ["import PATH", "parity PATH"]},
    {"outbox", ["failed", "replay EVENT_ID"]},
    # Nounless verbs. `whoami` sits here rather than under its own noun because
    # it takes no subcommand, and because it answers a question about the caller
    # rather than about the work.
    {"meta", ["version", "help", "whoami"]}
  ]
  @help_nouns @usage |> Enum.map(&elem(&1, 0)) |> List.delete("meta")

  @doc "Single-line usage summary, derived from the command table."
  def usage do
    @usage
    |> Enum.flat_map(fn
      {"meta", forms} -> forms
      {noun, forms} -> Enum.map(forms, &"#{noun} #{&1}")
    end)
    |> Enum.join("|")
  end

  @doc "Grouped help, one noun per entry."
  def help do
    %{
      usage: "sprucegoose <command> [args]",
      version: version(),
      commands:
        Map.new(@usage, fn
          {"meta", forms} -> {"meta", forms}
          {noun, forms} -> {noun, forms}
        end)
    }
  end

  @doc "Help for one top-level command family."
  def help(noun) when noun in @help_nouns do
    {_noun, forms} = List.keyfind!(@usage, noun, 0)

    %{
      usage: "sprucegoose #{noun} <command> [args]",
      version: version(),
      command: noun,
      forms: forms
    }
  end

  def version do
    case :application.get_key(:spruce_goose, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "unknown"
    end
  end

  def parse(["help"]), do: {:ok, :help}
  def parse(["--help"]), do: {:ok, :help}
  def parse(["-h"]), do: {:ok, :help}
  def parse(["version"]), do: {:ok, :version}
  def parse(["--version"]), do: {:ok, :version}

  def parse([noun, help]) when noun in @help_nouns and help in ["help", "--help", "-h"],
    do: {:ok, {:help, noun}}

  def parse(["id"]), do: {:ok, :generate_id}
  def parse(["validate-id", id]), do: {:ok, {:validate_id, id}}

  def parse(["project", "add", key | name]) when name != [],
    do: {:ok, {:add_project, key, Enum.join(name, " ")}}

  def parse(["project", "list"]), do: {:ok, :list_projects}
  def parse(["project", "show", key]), do: {:ok, {:show_project, key}}

  def parse(["project", "rename", key | name]) when name != [],
    do: {:ok, {:rename_project, key, Enum.join(name, " ")}}

  def parse(["project", "remove", key]), do: {:ok, {:remove_project, key}}

  def parse(["roadmap", "add", project, key | name]) when name != [],
    do: {:ok, {:add_roadmap, project, key, Enum.join(name, " ")}}

  def parse(["roadmap", "list" | args]) do
    with {:ok, opts} <- scope_options(args, project: :string) do
      {:ok, {:list_roadmaps, Keyword.get(opts, :project)}}
    end
  end

  def parse(["roadmap", "show", project, key]), do: {:ok, {:show_roadmap, project, key}}

  def parse(["roadmap", "rename", project, key | name]) when name != [],
    do: {:ok, {:rename_roadmap, project, key, Enum.join(name, " ")}}

  def parse(["roadmap", "remove", project, key]), do: {:ok, {:remove_roadmap, project, key}}

  def parse(["workflow", "list" | args]) do
    with {:ok, opts} <- scope_options(args, project: :string, roadmap: :string) do
      {:ok, {:list_workflows, Keyword.get(opts, :project), Keyword.get(opts, :roadmap)}}
    end
  end

  def parse(["workflow", "show", project, roadmap, workflow_id]),
    do: {:ok, {:show_workflow, project, roadmap, workflow_id}}

  def parse(["workflow", "rename", project, roadmap, workflow_id | name]) when name != [],
    do: {:ok, {:rename_workflow, project, roadmap, workflow_id, Enum.join(name, " ")}}

  def parse(["workflow", "remove", project, roadmap, workflow_id]),
    do: {:ok, {:remove_workflow, project, roadmap, workflow_id}}

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

  def parse(["task", "list" | args]) do
    case OptionParser.parse(args,
           strict: [
             state: :string,
             project: :string,
             roadmap: :string,
             workflow: :string,
             type: :string,
             label: :string,
             assignee: :string,
             priority: :string,
             text: :string,
             limit: :integer,
             offset: :integer,
             sort: :string
           ]
         ) do
      {opts, [], []} -> {:ok, {:list_tasks, Map.new(opts)}}
      _ -> {:error, "invalid task list arguments"}
    end
  end

  def parse(["task", "propose", id]), do: {:ok, {:transition_task, id, :proposed, nil}}
  def parse(["task", "queue", id]), do: {:ok, {:transition_task, id, :queued, nil}}
  def parse(["task", "ready", id]), do: {:ok, {:transition_task, id, :ready, nil}}
  def parse(["task", "start", id]), do: {:ok, {:transition_task, id, :in_progress, nil}}
  def parse(["task", "done", id]), do: {:ok, {:transition_task, id, :completed, nil}}

  def parse(["task", "cancel", id | reason]) when reason != [],
    do: {:ok, {:transition_task, id, :cancelled, Enum.join(reason, " ")}}

  def parse(["task", "wait", id | reason]) when reason != [],
    do: {:ok, {:transition_task, id, :waiting, Enum.join(reason, " ")}}

  def parse(["task", "link", id, "--remove", kind, value]),
    do: {:ok, {:unlink_task, id, kind, value}}

  def parse(["task", "link", id, kind, value]),
    do: {:ok, {:link_task, id, kind, value}}

  def parse(["task", "acknowledge-sop", id, sop_path]),
    do: {:ok, {:acknowledge_sop, id, sop_path}}

  def parse(["task", "artifact-receipt", id, json]),
    do: {:ok, {:record_artifact_receipt, id, json}}

  def parse(["dep", "list", task_id]), do: {:ok, {:list_dependencies, task_id}}

  def parse(["dep", "add", task_id | args]) do
    with {:ok, predecessor} <- dependency_option(args) do
      {:ok, {:add_dependency, task_id, predecessor}}
    end
  end

  def parse(["dep", "remove", task_id | args]) do
    with {:ok, predecessor} <- dependency_option(args) do
      {:ok, {:remove_dependency, task_id, predecessor}}
    end
  end

  def parse(["inbox", "list" | args]) do
    with {:ok, opts} <- scope_options(args, state: :string) do
      {:ok, {:list_inbox, Keyword.get(opts, :state)}}
    end
  end

  def parse(["inbox", "add" | body]) when body != [],
    do: {:ok, {:add_inbox, Enum.join(body, " ")}}

  def parse(["inbox", "done", capture_id]), do: {:ok, {:resolve_inbox, capture_id, nil}}

  def parse(["inbox", "drop", capture_id | reason]) when reason != [],
    do: {:ok, {:drop_inbox, capture_id, Enum.join(reason, " ")}}

  def parse(["inbox", "promote", capture_id | args]) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          project: :string,
          roadmap: :string,
          workflow: :string,
          priority: :integer,
          dod: :string,
          sop: :string,
          type: :string,
          title: :string
        ]
      )

    task_type = Keyword.get(opts, :type, "task")

    with [] <- invalid,
         [] <- rest,
         {:ok, project} <- required(opts, :project),
         {:ok, roadmap} <- required(opts, :roadmap),
         {:ok, workflow} <- required(opts, :workflow),
         {:ok, priority} <- required_priority(opts),
         {:ok, dod} <- required(opts, :dod),
         {:ok, sop_path} <- required(opts, :sop),
         true <- task_type in ["task", "diagnosis"] do
      {:ok,
       {:promote_inbox, capture_id,
        %{
          project: project,
          roadmap: roadmap,
          workflow: workflow,
          priority: priority,
          definition_of_done: dod,
          sop_path: sop_path,
          task_type: if(task_type == "diagnosis", do: :diagnosis, else: :task),
          title: Keyword.get(opts, :title)
        }}}
    else
      false -> {:error, "--type must be task or diagnosis"}
      {:error, :priority_range} -> {:error, "--priority must be between 0 and 5"}
      {:error, option} -> {:error, "--#{option} is required"}
      _ -> {:error, "invalid inbox promote arguments"}
    end
  end

  def parse(["todo", "list", task_id]), do: {:ok, {:list_todos, task_id}}

  def parse(["todo", "add", task_id | body]) when body != [],
    do: {:ok, {:add_todo, task_id, Enum.join(body, " ")}}

  def parse(["todo", "done", task_id, todo_id]),
    do: {:ok, {:complete_todo, task_id, todo_id}}

  def parse(["todo", "remove", task_id, todo_id]),
    do: {:ok, {:remove_todo, task_id, todo_id}}

  def parse(["todo", "dep", "list", task_id]), do: {:ok, {:list_todo_dependencies, task_id}}

  def parse(["todo", "dep", "add", task_id, todo_id | args]) do
    with {:ok, predecessor} <- dependency_option(args) do
      {:ok, {:add_todo_dependency, task_id, todo_id, predecessor}}
    end
  end

  def parse(["todo", "dep", "remove", task_id, todo_id | args]) do
    with {:ok, predecessor} <- dependency_option(args) do
      {:ok, {:remove_todo_dependency, task_id, todo_id, predecessor}}
    end
  end

  def parse(["board", "add", project, roadmap, workflow, key | name]) when name != [],
    do: {:ok, {:add_board, project, roadmap, workflow, key, Enum.join(name, " ")}}

  def parse(["board", "list", project, roadmap, workflow]),
    do: {:ok, {:list_boards, project, roadmap, workflow}}

  def parse(["board", "rename", board_id | name]) when name != [],
    do: {:ok, {:rename_board, board_id, Enum.join(name, " ")}}

  def parse(["board", "remove", board_id]), do: {:ok, {:remove_board, board_id}}

  def parse(["column", "add", board_id, key, position, state | name]) when name != [],
    do: {:ok, {:add_column, board_id, key, position, state, Enum.join(name, " ")}}

  def parse(["column", "list", board_id]), do: {:ok, {:list_columns, board_id}}

  def parse(["column", "rename", column_id | name]) when name != [],
    do: {:ok, {:rename_column, column_id, Enum.join(name, " ")}}

  def parse(["column", "remove", column_id]), do: {:ok, {:remove_column, column_id}}

  def parse(["task", "move", task_id, board_id, column_id, rank]),
    do: {:ok, {:move_task, task_id, board_id, column_id, rank}}

  def parse(["task", "metadata", task_id, json]),
    do: {:ok, {:update_task_metadata, task_id, json}}

  def parse(["filter", "add", board_id, name, json]),
    do: {:ok, {:add_filter, board_id, name, json}}

  def parse(["filter", "list", board_id]), do: {:ok, {:list_filters, board_id}}
  def parse(["filter", "apply", filter_id]), do: {:ok, {:apply_filter, filter_id}}
  def parse(["filter", "remove", filter_id]), do: {:ok, {:remove_filter, filter_id}}

  def parse(["revise", "propose" | args]) do
    with {:ok, opts} <- revise_options(args, file: :string),
         {:ok, file} <- required(opts, :file) do
      {:ok, {:propose_revision, file}}
    else
      {:error, option} when is_atom(option) -> {:error, "--#{option} is required"}
      error -> error
    end
  end

  def parse(["revise", "list" | args]) do
    with {:ok, opts} <- scope_options(args, state: :string, target: :string) do
      {:ok, {:list_revisions, Keyword.get(opts, :state), Keyword.get(opts, :target)}}
    end
  end

  def parse(["revise", "show", revision_id]), do: {:ok, {:show_revision, revision_id}}

  # Every flag is required, --digest above all: quoting back the digest that
  # `revise show` printed is what makes approval a sign-off rather than a
  # second keystroke.
  def parse(["revise", "approve", revision_id | args]) do
    with {:ok, opts} <- revise_options(args, task: :string, digest: :string, self: :boolean),
         {:ok, task} <- required(opts, :task),
         {:ok, digest} <- required(opts, :digest) do
      {:ok, {:approve_revision, revision_id, task, digest, Keyword.get(opts, :self, false)}}
    else
      {:error, option} when is_atom(option) -> {:error, "--#{option} is required"}
      error -> error
    end
  end

  def parse(["revise", "withdraw", revision_id | reason]) when reason != [],
    do: {:ok, {:withdraw_revision, revision_id, Enum.join(reason, " ")}}

  def parse(["whoami"]), do: {:ok, :whoami}

  def parse(["actor", "add", name | args]) do
    with {:ok, opts} <- revise_options(args, kind: :string, description: :string),
         {:ok, kind} <- required(opts, :kind),
         true <- kind in SpruceGoose.Actors.Registry.valid_kinds() do
      {:ok,
       {:add_actor,
        %{
          name: name,
          kind: String.to_existing_atom(kind),
          description: Keyword.get(opts, :description)
        }}}
    else
      false -> {:error, "--kind must be one of human, agent, system"}
      {:error, option} when is_atom(option) -> {:error, "--#{option} is required"}
      error -> error
    end
  end

  def parse(["actor", "list" | args]) do
    with {:ok, opts} <- scope_options(args, kind: :string) do
      {:ok, {:list_actors, Keyword.get(opts, :kind)}}
    end
  end

  def parse(["actor", "show", name]), do: {:ok, {:show_actor, name}}

  def parse(["actor", "disable", name | reason]) when reason != [],
    do: {:ok, {:disable_actor, name, Enum.join(reason, " ")}}

  def parse(["actor", "enable", name]), do: {:ok, {:enable_actor, name}}

  def parse(["grant", "add", name | args]) do
    with {:ok, opts} <- revise_options(args, role: :string, scope: :string),
         {:ok, role} <- required(opts, :role),
         {:ok, scope} <- required(opts, :scope) do
      {:ok, {:grant_role, name, role, scope}}
    else
      {:error, option} when is_atom(option) -> {:error, "--#{option} is required"}
      error -> error
    end
  end

  def parse(["grant", "list" | args]) do
    with {:ok, opts} <- scope_options(args, actor: :string, role: :string) do
      {:ok, {:list_grants, Keyword.get(opts, :actor), Keyword.get(opts, :role)}}
    end
  end

  def parse(["grant", "remove", name | args]) do
    with {:ok, opts} <- revise_options(args, role: :string, scope: :string),
         {:ok, role} <- required(opts, :role),
         {:ok, scope} <- required(opts, :scope) do
      {:ok, {:revoke_role, name, role, scope}}
    else
      {:error, option} when is_atom(option) -> {:error, "--#{option} is required"}
      error -> error
    end
  end

  def parse(["ledger", "import", path]), do: {:ok, {:import_ledger, path}}
  def parse(["ledger", "parity", path]), do: {:ok, {:parity_ledger, path}}
  def parse(["outbox", "failed"]), do: {:ok, :list_failed_outbox}
  def parse(["outbox", "replay", event_id]), do: {:ok, {:replay_outbox, event_id}}

  def parse(["task", "add" | args]) do
    {opts, title, invalid} =
      OptionParser.parse(args,
        strict: [
          project: :string,
          roadmap: :string,
          workflow: :string,
          priority: :integer,
          dod: :string,
          sop: :string,
          type: :string,
          artifact: :keep
        ]
      )

    task_type = Keyword.get(opts, :type, "task")

    with [] <- invalid,
         {:ok, project} <- required(opts, :project),
         {:ok, roadmap} <- required(opts, :roadmap),
         {:ok, workflow} <- required(opts, :workflow),
         {:ok, priority} <- required_priority(opts),
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
          priority: priority,
          definition_of_done: dod,
          sop_path: sop_path,
          task_type: if(task_type == "diagnosis", do: :diagnosis, else: :task),
          artifact_requirements: Keyword.get_values(opts, :artifact),
          title: title
        }}}
    else
      false -> {:error, "--type must be task or diagnosis"}
      {:error, :priority_range} -> {:error, "--priority must be between 0 and 5"}
      "" -> {:error, "task title is required"}
      {:error, option} -> {:error, "--#{option} is required"}
      _ -> {:error, "invalid task add arguments"}
    end
  end

  def parse(_args), do: {:error, :usage}

  defp dependency_option(args) do
    case OptionParser.parse(args, strict: [after: :string]) do
      {opts, [], []} ->
        case Keyword.get(opts, :after) do
          value when is_binary(value) and value != "" -> {:ok, value}
          _ -> {:error, "--after is required"}
        end

      _ ->
        {:error, "invalid dependency arguments"}
    end
  end

  @doc """
  Pop a global `--as NAME` (or `--as=NAME`) out of the argument list.

  Returns `{name_or_nil, remaining_args}`. Done before `parse/1` because every
  verb parses with `strict:`, so a flag that is not declared on that specific
  verb is an error rather than a global option.
  """
  def extract_actor(args), do: extract_actor(args, nil, [])

  defp extract_actor([], name, seen), do: {name, Enum.reverse(seen)}

  defp extract_actor(["--as", name | rest], _previous, seen),
    do: extract_actor(rest, name, seen)

  defp extract_actor(["--as=" <> name | rest], _previous, seen),
    do: extract_actor(rest, name, seen)

  defp extract_actor([arg | rest], name, seen), do: extract_actor(rest, name, [arg | seen])

  defp revise_options(args, strict) do
    case OptionParser.parse(args, strict: strict) do
      {opts, [], []} -> {:ok, opts}
      _ -> {:error, "invalid revise arguments"}
    end
  end

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

  defp required_priority(opts) do
    case Keyword.fetch(opts, :priority) do
      {:ok, priority} when priority in 0..5 -> {:ok, priority}
      {:ok, _priority} -> {:error, :priority_range}
      :error -> {:error, :priority}
    end
  end
end
