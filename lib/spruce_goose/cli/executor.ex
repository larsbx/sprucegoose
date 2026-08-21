defmodule SpruceGoose.CLI.Executor do
  @moduledoc false

  require Ash.Query
  import Ash.Expr

  alias SpruceGoose.Actors.{Refusal, Registry, Resolver}
  alias SpruceGoose.CLI.Command
  alias SpruceGoose.Outbox.Operator, as: OutboxOperator
  alias SpruceGoose.{Authz, Ledger, Legibility, Repo, Revise, SopGate, TaskId}

  alias SpruceGoose.Workflows.{
    Board,
    BoardColumn,
    BlueprintRevision,
    Dependency,
    Graph,
    InboxItem,
    Project,
    Roadmap,
    SavedFilter,
    Task,
    TaskState,
    Todo,
    TodoDependency,
    Workflow
  }

  # Commands that touch no data and reveal nothing about it. They answer before
  # an actor is resolved so that `help` still works on a cold registry — the
  # same reason genesis exists.
  @unauthenticated [:help, :version, :generate_id]

  @doc "Execute only boot-free, read-only release provenance commands."
  def run_read_only({:inspect_release_provenance, archive}) do
    SpruceGoose.ReleaseValidator.inspect_archive(archive)
  end

  def run_read_only({:validate_release_provenance, archive, opts}) do
    SpruceGoose.ReleaseValidator.validate(Keyword.put(opts, :archive, archive))
  end

  def run_read_only(_), do: {:error, "not a read-only release provenance command"}

  @registry_verbs [
    :add_actor,
    :list_actors,
    :show_actor,
    :disable_actor,
    :enable_actor,
    :grant_role,
    :revoke_role,
    :list_grants
  ]

  @doc """
  Run one parsed command as `actor_name`.

  The actor is resolved once and established for the whole request via
  `SpruceGoose.Authz.with_actor/2`; nothing downstream takes it as an argument,
  and anything that reaches Ash without it raises rather than running
  unauthorized.
  """
  def run(command, actor_name \\ nil)

  def run(command, _actor_name) when command in @unauthenticated, do: dispatch(command)
  def run({:help, _noun} = command, _actor_name), do: dispatch(command)
  def run({:validate_id, _id} = command, _actor_name), do: dispatch(command)

  # Registry commands resolve the actor *optionally*: on an empty registry there
  # is nobody to resolve, and `Registry.add/2` is what opens the genesis path.
  # Refusing here would make the registry unbootstrappable.
  def run({verb, _} = command, actor_name) when verb in @registry_verbs,
    do: registry(command, resolve_optional(actor_name))

  def run({verb, _, _} = command, actor_name) when verb in @registry_verbs,
    do: registry(command, resolve_optional(actor_name))

  def run({verb, _, _, _} = command, actor_name) when verb in @registry_verbs,
    do: registry(command, resolve_optional(actor_name))

  def run(:whoami, actor_name) do
    case Resolver.resolve(actor_name) do
      {:ok, actor} -> Registry.whoami(actor)
      {:error, message} -> {:error, message}
    end
  end

  def run(command, actor_name) do
    case Resolver.resolve(actor_name) do
      {:ok, actor} ->
        actor
        |> Authz.with_actor(fn -> dispatch(command) end)
        |> explain(actor)

      {:error, message} ->
        {:error, message}
    end
  end

  # A refusal is only useful if it names the grant that was missing, so an Ash
  # policy error is translated before it leaves the CLI.
  defp explain({:error, %Ash.Error.Forbidden{} = error}, actor),
    do: {:error, Refusal.message(error, actor)}

  defp explain(result, _actor), do: result

  defp registry({:add_actor, attrs}, acting), do: Registry.add(attrs, acting)
  defp registry({:list_actors, kind}, acting), do: Registry.list(kind, acting)
  defp registry({:show_actor, name}, acting), do: Registry.show(name, acting)

  defp registry({:disable_actor, name, reason}, acting),
    do: Registry.disable(name, reason, acting)

  defp registry({:enable_actor, name}, acting), do: Registry.enable(name, acting)

  defp registry({:grant_role, name, role, scope}, acting),
    do: Registry.grant(name, role, scope, acting)

  defp registry({:revoke_role, name, role, scope}, acting),
    do: Registry.revoke(name, role, scope, acting)

  defp registry({:list_grants, name, role}, acting), do: Registry.grants(name, role, acting)

  defp resolve_optional(actor_name) do
    case Resolver.resolve(actor_name) do
      {:ok, actor} -> actor
      {:error, _message} -> nil
    end
  end

  defp dispatch(:help), do: {:ok, Command.help()}
  defp dispatch({:help, noun}), do: {:ok, Command.help(noun)}
  defp dispatch(:version), do: {:ok, %{version: Command.version()}}

  defp dispatch(:generate_id), do: {:ok, %{id: TaskId.generate()}}
  defp dispatch(:list_failed_outbox), do: OutboxOperator.list_failed()
  defp dispatch({:replay_outbox, event_id}), do: OutboxOperator.replay(event_id)

  defp dispatch({:validate_id, id}) do
    if TaskId.valid?(id), do: {:ok, %{id: id, valid: true}}, else: {:error, "invalid task ID"}
  end

  defp dispatch({:add_project, key, name}) do
    with {:ok, project} <- Authz.create(Project, %{key: key, name: name}) do
      {:ok, project_json(project)}
    end
  end

  defp dispatch(:list_projects) do
    with {:ok, projects} <- Authz.read(Project) do
      {:ok, %{projects: projects |> Enum.sort_by(& &1.key) |> Enum.map(&project_json/1)}}
    end
  end

  defp dispatch({:show_project, key}) do
    with {:ok, project} <- read_one(Project, key: key) do
      {:ok, project_json(project)}
    end
  end

  defp dispatch({:view_project, key}), do: Legibility.project(key)

  defp dispatch({:register_blueprint, project_key, repository, commit, tree, path, digest}) do
    with {:ok, project} <- read_one(Project, key: project_key),
         {:ok, revision} <-
           Authz.create(
             BlueprintRevision,
             %{
               project_id: project.id,
               repository: repository,
               source_commit: commit,
               source_tree: tree,
               source_path: path,
               manifest_digest: digest,
               schema_version: 1
             },
             action: :register
           ) do
      {:ok,
       %{
         id: revision.revision_id,
         project: project_key,
         repository: revision.repository,
         commit: revision.source_commit,
         tree: revision.source_tree,
         path: revision.source_path,
         digest: revision.manifest_digest,
         schema_version: revision.schema_version
       }}
    end
  end

  defp dispatch({:list_roadmaps, project_key}) do
    with {:ok, filter} <- roadmap_scope(project_key),
         {:ok, roadmaps} <- Authz.read(Ash.Query.filter_input(Roadmap, filter)),
         {:ok, projects} <- Authz.read(Project) do
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

  defp dispatch({:show_roadmap, project_key, key}) do
    with {:ok, project} <- read_one(Project, key: project_key),
         {:ok, roadmap} <- read_one(Roadmap, project_id: project.id, key: key) do
      {:ok, Map.put(roadmap_json(roadmap), :project, project.key)}
    end
  end

  defp dispatch({:list_workflows, project_key, roadmap_key}) do
    with {:ok, roadmap_ids} <- workflow_scope(project_key, roadmap_key),
         filter = if(roadmap_ids, do: [roadmap_id: [in: roadmap_ids]], else: []),
         {:ok, workflows} <- Authz.read(Ash.Query.filter_input(Workflow, filter)),
         {:ok, labels} <- roadmap_labels(),
         {:ok, tasks} <- Authz.read(Task) do
      # Live vs. done counts let an operator spot an active workflow without
      # issuing a follow-up task list per workflow.
      by_workflow = Enum.group_by(tasks, & &1.workflow_id)

      {:ok,
       %{
         workflows:
           workflows
           |> Enum.sort_by(&{Map.get(labels, &1.roadmap_id), &1.workflow_id})
           |> Enum.map(fn workflow ->
             rows = Map.get(by_workflow, workflow.id, [])
             counts = Enum.frequencies_by(rows, &to_string(&1.state))

             %{
               id: workflow.id,
               roadmap_id: workflow.roadmap_id,
               roadmap: Map.get(labels, workflow.roadmap_id),
               workflow_id: workflow.workflow_id,
               name: workflow.name,
               task_count: length(rows),
               open_count:
                 Enum.count(rows, &(to_string(&1.state) not in ["completed", "cancelled"])),
               state_counts: counts
             }
           end)
       }}
    end
  end

  defp dispatch({:show_workflow, project_key, roadmap_key, workflow_key}) do
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

  defp dispatch({:workflow_critical_path, project_key, roadmap_key, workflow_key}) do
    with {:ok, workflow} <- resolve_workflow(project_key, roadmap_key, workflow_key),
         {:ok, path} <- Graph.critical_path(workflow) do
      {:ok,
       path
       |> Map.put(:project, project_key)
       |> Map.put(:roadmap, roadmap_key)
       |> Map.put(:workflow, workflow_key)}
    end
  end

  defp dispatch({:rename_project, key, name}) do
    with {:ok, project} <- read_one(Project, key: key),
         {:ok, project} <- Authz.update(project, %{name: name}, action: :rename) do
      {:ok, project_json(project)}
    end
  end

  defp dispatch({:remove_project, key}) do
    with {:ok, project} <- read_one(Project, key: key),
         :ok <- require_no_dependents(Roadmap, [project_id: project.id], "roadmaps"),
         :ok <- destroy(project) do
      {:ok, %{removed: project_json(project)}}
    end
  end

  defp dispatch({:rename_roadmap, project_key, key, name}) do
    with {:ok, project} <- read_one(Project, key: project_key),
         {:ok, roadmap} <- read_one(Roadmap, project_id: project.id, key: key),
         {:ok, roadmap} <- Authz.update(roadmap, %{name: name}, action: :rename) do
      {:ok, Map.put(roadmap_json(roadmap), :project, project.key)}
    end
  end

  defp dispatch({:remove_roadmap, project_key, key}) do
    with {:ok, project} <- read_one(Project, key: project_key),
         {:ok, roadmap} <- read_one(Roadmap, project_id: project.id, key: key),
         :ok <- require_no_dependents(Workflow, [roadmap_id: roadmap.id], "workflows"),
         :ok <- destroy(roadmap) do
      {:ok, %{removed: Map.put(roadmap_json(roadmap), :project, project.key)}}
    end
  end

  defp dispatch({:rename_workflow, project_key, roadmap_key, workflow_key, name}) do
    with {:ok, workflow} <- resolve_workflow(project_key, roadmap_key, workflow_key),
         {:ok, workflow} <- Authz.update(workflow, %{name: name}, action: :rename) do
      {:ok, workflow_json(workflow)}
    end
  end

  defp dispatch({:remove_workflow, project_key, roadmap_key, workflow_key}) do
    with {:ok, workflow} <- resolve_workflow(project_key, roadmap_key, workflow_key),
         :ok <- require_no_dependents(Task, [workflow_id: workflow.id], "tasks"),
         :ok <- require_no_dependents(Board, [workflow_id: workflow.id], "boards"),
         :ok <- destroy(workflow) do
      {:ok, %{removed: workflow_json(workflow)}}
    end
  end

  defp dispatch({:rename_board, board_id, name}) do
    with {:ok, board} <- read_one(Board, id: board_id),
         {:ok, board} <- Authz.update(board, %{name: name}, action: :rename) do
      {:ok, board_json(board)}
    end
  end

  defp dispatch({:remove_board, board_id}) do
    with {:ok, board} <- read_one(Board, id: board_id),
         :ok <- require_no_dependents(BoardColumn, [board_id: board.id], "columns"),
         :ok <- require_no_dependents(SavedFilter, [board_id: board.id], "filters"),
         :ok <- require_no_dependents(Task, [board_id: board.id], "tasks"),
         :ok <- destroy(board) do
      {:ok, %{removed: board_json(board)}}
    end
  end

  defp dispatch({:rename_column, column_id, name}) do
    with {:ok, column} <- read_one(BoardColumn, id: column_id),
         {:ok, column} <- Authz.update(column, %{name: name}, action: :rename) do
      {:ok, column_json(column)}
    end
  end

  defp dispatch({:remove_column, column_id}) do
    with {:ok, column} <- read_one(BoardColumn, id: column_id),
         :ok <- require_no_dependents(Task, [column_id: column.id], "tasks"),
         :ok <- destroy(column) do
      {:ok, %{removed: column_json(column)}}
    end
  end

  defp dispatch({:remove_filter, filter_id}) do
    with {:ok, filter} <- read_one(SavedFilter, id: filter_id),
         :ok <- destroy(filter) do
      {:ok, %{removed: filter_json(filter)}}
    end
  end

  defp dispatch({:list_todo_dependencies, task_id}) do
    with :ok <- require_valid_id(task_id),
         {:ok, task} <- read_one(Task, task_id: task_id),
         {:ok, todos} <- Authz.read(Ash.Query.filter_input(Todo, task_id: task.id)),
         {:ok, edges} <- Authz.read(Ash.Query.filter_input(TodoDependency, task_id: task.id)) do
      by_id = Map.new(todos, &{&1.id, &1})
      predecessors_of = Enum.group_by(edges, & &1.successor_id, & &1.predecessor_id)
      successors_of = Enum.group_by(edges, & &1.predecessor_id, & &1.successor_id)

      {:ok,
       %{
         task: task.task_id,
         todos:
           todos
           |> Enum.sort_by(& &1.position)
           |> Enum.map(fn todo ->
             blockers =
               predecessors_of
               |> Map.get(todo.id, [])
               |> Enum.map(&Map.fetch!(by_id, &1))

             %{
               id: todo.todo_id,
               body: todo.body,
               position: todo.position,
               completed: todo.completed,
               blocked: Enum.any?(blockers, &(not &1.completed)),
               depends_on: blockers |> Enum.map(&todo_edge_json/1) |> Enum.sort_by(& &1.id),
               blocks:
                 successors_of
                 |> Map.get(todo.id, [])
                 |> Enum.map(&Map.fetch!(by_id, &1))
                 |> Enum.map(&todo_edge_json/1)
                 |> Enum.sort_by(& &1.id)
             }
           end)
       }}
    end
  end

  defp dispatch({:add_todo_dependency, task_id, todo_id, predecessor_id}) do
    with {:ok, task, successor, predecessor} <-
           todo_dependency_pair(task_id, todo_id, predecessor_id),
         :ok <- require_new_todo_edge(successor, predecessor),
         :ok <- require_acyclic_todo(task, successor, predecessor),
         {:ok, edge} <-
           Authz.create(TodoDependency, %{
             task_id: task.id,
             predecessor_id: predecessor.id,
             successor_id: successor.id
           }) do
      {:ok,
       %{
         id: edge.id,
         task: task.task_id,
         todo: successor.todo_id,
         depends_on: predecessor.todo_id
       }}
    end
  end

  defp dispatch({:remove_todo_dependency, task_id, todo_id, predecessor_id}) do
    with {:ok, task, successor, predecessor} <-
           todo_dependency_pair(task_id, todo_id, predecessor_id),
         {:ok, edge} <-
           read_one(TodoDependency,
             predecessor_id: predecessor.id,
             successor_id: successor.id
           ),
         :ok <- destroy(edge) do
      {:ok,
       %{
         removed: edge.id,
         task: task.task_id,
         todo: successor.todo_id,
         depends_on: predecessor.todo_id
       }}
    end
  end

  defp dispatch({:remove_todo, task_id, todo_id}) do
    with :ok <- require_valid_id(task_id),
         {:ok, task} <- read_one(Task, task_id: task_id),
         :ok <- todo_admission_allowed(task),
         {:ok, todo} <- read_one(Todo, task_id: task.id, todo_id: todo_id),
         :ok <- destroy(todo) do
      {:ok, %{removed: todo_json(todo)}}
    end
  end

  defp dispatch({:unlink_task, id, kind, value}) do
    with :ok <- require_valid_id(id),
         {:ok, task} <- read_one(Task, task_id: id),
         references = Map.get(task.input, "references", []),
         target = %{"kind" => kind, "value" => value},
         true <- target in references,
         input = Map.put(task.input, "references", List.delete(references, target)),
         {:ok, task} <-
           task |> Ash.Changeset.for_update(:revise, %{input: input}) |> Authz.update_changeset() do
      {:ok, task_json(task)}
    else
      false -> {:error, "reference not found"}
      result -> result
    end
  end

  defp dispatch({:add_roadmap, project_key, key, name}) do
    with {:ok, project} <- read_one(Project, key: project_key),
         {:ok, roadmap} <-
           Authz.create(Roadmap, %{project_id: project.id, key: key, name: name}) do
      {:ok, roadmap_json(roadmap)}
    end
  end

  defp dispatch({:add_workflow, project_key, roadmap_key, workflow_id, name, definition_json}) do
    with {:ok, project} <- read_one(Project, key: project_key),
         {:ok, roadmap} <- read_one(Roadmap, project_id: project.id, key: roadmap_key),
         {:ok, definition_input} <- decode_json_object(definition_json),
         {:ok, definition} <- SpruceGoose.Workflows.Definition.parse(definition_input),
         {:ok, workflow} <-
           Authz.create(Workflow, %{
             roadmap_id: roadmap.id,
             workflow_id: workflow_id,
             name: name,
             definition: definition
           }) do
      {:ok, workflow_json(workflow)}
    end
  end

  defp dispatch({:propose_revision, path}), do: Revise.propose(path)
  defp dispatch({:list_revisions, state, target}), do: Revise.list(state, target)
  defp dispatch({:show_revision, revision_id}), do: Revise.show(revision_id)

  defp dispatch({:approve_revision, revision_id, task_id, digest, self?}),
    do: Revise.approve(revision_id, task_id, digest, self?)

  defp dispatch({:withdraw_revision, revision_id, reason}),
    do: Revise.withdraw(revision_id, reason)

  defp dispatch({:import_ledger, path}), do: Ledger.import(path)
  defp dispatch({:parity_ledger, path}), do: Ledger.parity(path)

  defp dispatch({:show_task, id}) do
    with :ok <- require_valid_id(id),
         {:ok, task} <- read_one(Task, task_id: id) do
      {:ok, task_json(task)}
    end
  end

  defp dispatch({:task_blockers, id}) do
    with :ok <- require_valid_id(id),
         {:ok, task} <- read_one(Task, task_id: id),
         {:ok, blockers} <- Graph.blockers(task) do
      {:ok, %{task: task.task_id, blockers: blockers}}
    end
  end

  defp dispatch({:task_impact, id}) do
    with :ok <- require_valid_id(id),
         {:ok, task} <- read_one(Task, task_id: id),
         {:ok, impacted} <- Graph.impact(task) do
      {:ok, %{task: task.task_id, impacted: impacted}}
    end
  end

  defp dispatch({:list_tasks, filters}) do
    with {:ok, states} <- optional_states(Map.get(filters, :state)),
         {:ok, task_type} <- optional_task_type(Map.get(filters, :type)),
         {:ok, priority} <- optional_priority(Map.get(filters, :priority)),
         {:ok, sort} <- optional_sort(Map.get(filters, :sort)),
         {:ok, limit} <- optional_window(Map.get(filters, :limit), "limit"),
         {:ok, offset} <- optional_window(Map.get(filters, :offset), "offset"),
         {:ok, workflow_ids} <- task_workflow_scope(filters),
         query =
           Task
           |> task_scope_query(states, task_type, workflow_ids, priority, filters)
           |> task_sort_query(sort),
         # Count in SQL against the same filters, so `total` describes the
         # whole match while only the requested window is materialised.
         {:ok, total} <- Authz.count(query),
         {:ok, tasks} <- Authz.read(paginate_query(query, limit, offset)),
         {:ok, memberships} <- workflow_memberships() do
      {:ok,
       %{
         total: total,
         count: length(tasks),
         offset: offset || 0,
         limit: limit,
         tasks: Enum.map(tasks, &task_json(&1, memberships))
       }}
    end
  end

  defp dispatch({:transition_task, id, target, reason}) do
    with :ok <- require_valid_id(id),
         {:ok, task} <- read_one(Task, task_id: id),
         :ok <- require_transition_preconditions(task, target),
         {:ok, task} <- transition(task, target, reason) do
      {:ok, task_json(task)}
    end
  end

  defp dispatch({:link_task, id, kind, value}) do
    with :ok <- require_valid_id(id),
         {:ok, task} <- read_one(Task, task_id: id),
         references = Map.get(task.input, "references", []),
         input =
           Map.put(task.input, "references", references ++ [%{"kind" => kind, "value" => value}]),
         {:ok, task} <-
           task |> Ash.Changeset.for_update(:revise, %{input: input}) |> Authz.update_changeset() do
      {:ok, task_json(task)}
    end
  end

  defp dispatch({:acknowledge_sop, id, sop_path}) do
    with :ok <- require_valid_id(id),
         {:ok, task} <- read_one(Task, task_id: id),
         :ok <- sop_acknowledgment_allowed(task),
         true <- sop_path == SopGate.path(),
         {:ok, task} <-
           task
           |> Ash.Changeset.for_update(:acknowledge_sop, %{})
           |> Authz.update_changeset() do
      {:ok, task_json(task)}
    else
      false -> {:error, "SOP path must be #{SopGate.path()}"}
      result -> result
    end
  end

  defp dispatch({:record_artifact_receipt, id, name, source_path, source_identity}) do
    with :ok <- require_valid_id(id),
         {:ok, task} <- read_one(Task, task_id: id),
         :ok <- require_distinct_artifact_verifier(task),
         {:ok, receipt} <-
           SpruceGoose.Artifacts.Store.retrieve(
             name,
             source_path,
             source_identity,
             Authz.actor!().name
           ),
         receipts = (task.artifact_receipts || []) ++ [receipt],
         {:ok, task} <-
           task
           |> Ash.Changeset.for_update(:record_artifact_receipt, %{artifact_receipts: receipts})
           |> Authz.update_changeset() do
      {:ok, task_json(task)}
    end
  end

  defp dispatch({:list_dependencies, task_id}) do
    with :ok <- require_valid_id(task_id),
         {:ok, task} <- read_one(Task, task_id: task_id),
         {:ok, task} <- Ash.load(task, predecessor_edges: [:predecessor]),
         {:ok, task} <- Ash.load(task, successor_edges: [:successor]) do
      {:ok,
       %{
         task: task.task_id,
         state: task.state,
         blocked: Enum.any?(task.predecessor_edges, &(&1.predecessor.state != :completed)),
         predecessors:
           task.predecessor_edges
           |> Enum.map(&edge_json(&1, &1.predecessor))
           |> Enum.sort_by(& &1.task),
         successors:
           task.successor_edges
           |> Enum.map(&edge_json(&1, &1.successor))
           |> Enum.sort_by(& &1.task)
       }}
    end
  end

  defp dispatch({:add_dependency, task_id, predecessor_id}) do
    with {:ok, successor, predecessor} <- dependency_pair(task_id, predecessor_id),
         :ok <- require_same_workflow(successor, predecessor),
         :ok <- require_new_edge(successor, predecessor),
         :ok <- require_acyclic(successor, predecessor),
         {:ok, edge} <-
           Authz.create(Dependency, %{
             predecessor_id: predecessor.id,
             successor_id: successor.id,
             source: "native"
           }) do
      {:ok,
       %{
         id: edge.id,
         task: successor.task_id,
         depends_on: predecessor.task_id,
         source: edge.source
       }}
    end
  end

  defp dispatch({:remove_dependency, task_id, predecessor_id}) do
    with {:ok, successor, predecessor} <- dependency_pair(task_id, predecessor_id),
         {:ok, edge} <-
           read_one(Dependency, predecessor_id: predecessor.id, successor_id: successor.id),
         :ok <- Authz.destroy(edge) do
      {:ok,
       %{
         removed: edge.id,
         task: successor.task_id,
         depends_on: predecessor.task_id
       }}
    end
  end

  defp dispatch({:add_inbox, body}) do
    with {:ok, item} <-
           Authz.create(InboxItem, %{capture_id: generate_record_id("inbox"), body: body}) do
      {:ok, inbox_json(item)}
    end
  end

  defp dispatch({:list_inbox, state}) do
    with {:ok, filter} <- inbox_scope(state),
         {:ok, items} <- Authz.read(Ash.Query.filter_input(InboxItem, filter)) do
      {:ok, %{items: items |> Enum.sort_by(& &1.capture_id) |> Enum.map(&inbox_json/1)}}
    end
  end

  defp dispatch({:resolve_inbox, capture_id, reason}) do
    with {:ok, item} <- read_one(InboxItem, capture_id: capture_id),
         {:ok, item} <- resolve_capture(item, :resolved, %{resolution_reason: reason}) do
      {:ok, inbox_json(item)}
    end
  end

  defp dispatch({:drop_inbox, capture_id, reason}) do
    with {:ok, item} <- read_one(InboxItem, capture_id: capture_id),
         {:ok, item} <- resolve_capture(item, :dropped, %{resolution_reason: reason}) do
      {:ok, inbox_json(item)}
    end
  end

  defp dispatch({:promote_inbox, capture_id, input}) do
    with {:ok, item} <- read_one(InboxItem, capture_id: capture_id),
         :ok <- require_open_capture(item),
         title = input.title || item.body,
         {:ok, task} <- run({:add_task, Map.put(input, :title, title)}),
         {:ok, item} <-
           resolve_capture(item, :resolved, %{
             resolution_reason: "promoted to #{task.id}",
             promoted_task_id: task.id
           }) do
      {:ok, %{capture: inbox_json(item), task: task}}
    end
  end

  defp dispatch({:list_todos, task_id}) do
    with :ok <- require_valid_id(task_id),
         {:ok, task} <- read_one(Task, task_id: task_id),
         {:ok, todos} <- Authz.read(Ash.Query.filter_input(Todo, task_id: task.id)) do
      {:ok, %{todos: todos |> Enum.sort_by(& &1.position) |> Enum.map(&todo_json/1)}}
    end
  end

  defp dispatch({:add_todo, task_id, body}) do
    with :ok <- require_valid_id(task_id),
         {:ok, task} <- read_one(Task, task_id: task_id),
         {:ok, todo} <- create_todo(task, generate_record_id("todo"), body) do
      {:ok, todo_json(todo)}
    end
  end

  defp dispatch({:complete_todo, task_id, todo_id}) do
    with :ok <- require_valid_id(task_id),
         {:ok, task} <- read_one(Task, task_id: task_id),
         {:ok, todo} <- read_one(Todo, task_id: task.id, todo_id: todo_id),
         :ok <- require_todo_predecessors_complete(task, todo),
         {:ok, todo} <- todo |> Ash.Changeset.for_update(:complete) |> Authz.update_changeset() do
      {:ok, todo_json(todo)}
    end
  end

  defp dispatch({:add_board, project_key, roadmap_key, workflow_key, key, name}) do
    with {:ok, project} <- read_one(Project, key: project_key),
         {:ok, roadmap} <- read_one(Roadmap, project_id: project.id, key: roadmap_key),
         {:ok, workflow} <-
           read_one(Workflow, roadmap_id: roadmap.id, workflow_id: workflow_key),
         {:ok, board} <-
           Authz.create(Board, %{workflow_id: workflow.id, key: key, name: name}) do
      {:ok, board_json(board)}
    end
  end

  defp dispatch({:list_boards, project_key, roadmap_key, workflow_key}) do
    with {:ok, project} <- read_one(Project, key: project_key),
         {:ok, roadmap} <- read_one(Roadmap, project_id: project.id, key: roadmap_key),
         {:ok, workflow} <-
           read_one(Workflow, roadmap_id: roadmap.id, workflow_id: workflow_key),
         {:ok, boards} <- Authz.read(Ash.Query.filter_input(Board, workflow_id: workflow.id)) do
      {:ok, %{boards: Enum.map(boards, &board_json/1)}}
    end
  end

  defp dispatch({:add_column, board_ref, key, position, state, name}) do
    with {position, ""} <- Integer.parse(position),
         {:ok, state} <- optional_state(state),
         {:ok, board_id} <- resolve_board_ref(board_ref),
         {:ok, column} <-
           Authz.create(BoardColumn, %{
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

  defp dispatch({:list_columns, board_ref}) do
    with {:ok, board_id} <- resolve_board_ref(board_ref),
         {:ok, columns} <- Authz.read(Ash.Query.filter_input(BoardColumn, board_id: board_id)) do
      {:ok, %{columns: columns |> Enum.sort_by(& &1.position) |> Enum.map(&column_json/1)}}
    end
  end

  defp dispatch({:move_task, task_id, board_ref, column_ref, rank}) do
    with :ok <- require_valid_id(task_id),
         {:ok, task} <- read_one(Task, task_id: task_id),
         {:ok, board_id} <- resolve_board_ref(board_ref),
         {:ok, column} <- resolve_column(board_id, column_ref),
         column_id = column.id,
         {:ok, task} <-
           Authz.update(
             task,
             %{board_id: board_id, column_id: column_id, rank: rank, to_state: column.task_state},
             action: :move
           ) do
      {:ok, task_json(task)}
    end
  end

  defp dispatch({:update_task_metadata, task_id, json}) do
    with :ok <- require_valid_id(task_id),
         {:ok, input} <- decode_metadata(json),
         {:ok, task} <- read_one(Task, task_id: task_id),
         {:ok, task} <- Authz.update(task, input, action: :update_board_metadata) do
      {:ok, task_json(task)}
    end
  end

  defp dispatch({:add_filter, board_ref, name, json}) do
    with {:ok, board_id} <- resolve_board_ref(board_ref),
         {:ok, criteria} <- decode_json_object(json),
         {:ok, filter} <-
           Authz.create(SavedFilter, %{board_id: board_id, name: name, criteria: criteria}) do
      {:ok, filter_json(filter)}
    end
  end

  defp dispatch({:list_filters, board_ref}) do
    with {:ok, board_id} <- resolve_board_ref(board_ref),
         {:ok, filters} <- Authz.read(Ash.Query.filter_input(SavedFilter, board_id: board_id)) do
      {:ok, %{filters: Enum.map(filters, &filter_json/1)}}
    end
  end

  defp dispatch({:apply_filter, filter_id}) do
    with {:ok, filter} <- read_one(SavedFilter, id: filter_id),
         {:ok, tasks} <- Authz.read(Ash.Query.filter_input(Task, board_id: filter.board_id)) do
      {:ok,
       %{
         tasks:
           tasks |> Enum.filter(&matches_filter?(&1, filter.criteria)) |> Enum.map(&task_json/1)
       }}
    end
  end

  defp dispatch({:add_task, input}) do
    with {:ok, priority} <- required_task_priority(input),
         {:ok, project} <- read_one(Project, key: input.project),
         {:ok, roadmap} <- read_one(Roadmap, project_id: project.id, key: input.roadmap),
         {:ok, workflow} <-
           read_one(Workflow, roadmap_id: roadmap.id, workflow_id: input.workflow),
         true <- input.sop_path == SopGate.path(),
         id = TaskId.generate(),
         {:ok, task} <-
           Authz.create(
             Task,
             %{
               workflow_id: workflow.id,
               task_id: id,
               task_type: input.task_type,
               title: input.title,
               definition_of_done: input.definition_of_done,
               priority: priority,
               artifact_requirements: Map.get(input, :artifact_requirements, []),
               runner: :oban
             }
           ) do
      {:ok, task_json(task)}
    else
      false -> {:error, "SOP path must be #{SopGate.path()}"}
      result -> result
    end
  end

  defp required_task_priority(input) do
    case Map.fetch(input, :priority) do
      {:ok, priority} when priority in 0..5 -> {:ok, priority}
      {:ok, _priority} -> {:error, "priority must be between 0 and 5"}
      :error -> {:error, "priority is required"}
    end
  end

  # Record identity is generated, never derived from content. Deriving
  # capture_id/todo_id from sha256(body) made two genuinely distinct records
  # with identical text collapse into one. Outbox dedup does not depend on
  # this: the inbox trigger keys ON CONFLICT on 'inbox:' || capture_id, so a
  # unique id still yields exactly one event per capture.
  defp generate_record_id(prefix) do
    prefix <> "-" <> (16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))
  end

  defp resolve_workflow(project_key, roadmap_key, workflow_key) do
    with {:ok, project} <- read_one(Project, key: project_key),
         {:ok, roadmap} <- read_one(Roadmap, project_id: project.id, key: roadmap_key) do
      read_one(Workflow, roadmap_id: roadmap.id, workflow_id: workflow_key)
    end
  end

  # Every foreign key is ON DELETE NO ACTION, so Postgres already refuses an
  # orphaning delete. These checks run first so the CLI reports which
  # dependents block removal instead of leaking a raw constraint error, and so
  # removal is never silently cascading.
  defp require_no_dependents(resource, filter, label) do
    with {:ok, rows} <- Authz.read(Ash.Query.filter_input(resource, filter)) do
      case length(rows) do
        0 -> :ok
        count -> {:error, "cannot remove while #{count} #{label} still reference it"}
      end
    end
  end

  defp destroy(record), do: Authz.destroy(record)

  defp todo_dependency_pair(task_id, todo_id, predecessor_id) do
    with :ok <- require_valid_id(task_id),
         {:ok, task} <- read_one(Task, task_id: task_id),
         {:ok, successor} <- read_one(Todo, task_id: task.id, todo_id: todo_id),
         {:ok, predecessor} <- read_one(Todo, task_id: task.id, todo_id: predecessor_id) do
      if successor.id == predecessor.id do
        {:error, "a TODO cannot depend on itself"}
      else
        {:ok, task, successor, predecessor}
      end
    end
  end

  defp require_new_todo_edge(successor, predecessor) do
    case read_one(TodoDependency,
           predecessor_id: predecessor.id,
           successor_id: successor.id
         ) do
      {:error, "not found"} -> :ok
      {:ok, _edge} -> {:error, "dependency already exists"}
      error -> error
    end
  end

  # Scoped to one task's edges. A new predecessor -> successor edge closes a
  # cycle exactly when successor is already reachable from predecessor.
  defp require_acyclic_todo(task, successor, predecessor) do
    with {:ok, edges} <- Authz.read(Ash.Query.filter_input(TodoDependency, task_id: task.id)) do
      predecessors_of = Enum.group_by(edges, & &1.successor_id, & &1.predecessor_id)

      if reaches?(predecessor.id, successor.id, predecessors_of, MapSet.new()) do
        {:error, "dependency would create a cycle"}
      else
        :ok
      end
    end
  end

  defp todo_edge_json(todo) do
    %{
      id: todo.todo_id,
      body: todo.body,
      position: todo.position,
      completed: todo.completed
    }
  end

  # TODOs default to fully concurrent: no edge means no constraint. A TODO is
  # blocked only while an explicit predecessor is still open.
  defp require_todo_predecessors_complete(task, todo) do
    with {:ok, edges} <-
           Authz.read(Ash.Query.filter_input(TodoDependency, successor_id: todo.id)),
         false <- edges == [],
         {:ok, todos} <- Authz.read(Ash.Query.filter_input(Todo, task_id: task.id)) do
      by_id = Map.new(todos, &{&1.id, &1})

      open =
        edges
        |> Enum.map(&Map.get(by_id, &1.predecessor_id))
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(& &1.completed)

      case open do
        [] ->
          :ok

        open ->
          names = open |> Enum.map(& &1.todo_id) |> Enum.sort() |> Enum.join(", ")
          {:error, "TODO is blocked by incomplete predecessors: #{names}"}
      end
    else
      # No edges at all: TODOs default to fully concurrent.
      true -> :ok
      error -> error
    end
  end

  defp dependency_pair(task_id, predecessor_id) do
    with :ok <- require_valid_id(task_id),
         :ok <- require_valid_id(predecessor_id),
         {:ok, successor} <- read_one(Task, task_id: task_id),
         {:ok, predecessor} <- read_one(Task, task_id: predecessor_id) do
      if successor.id == predecessor.id do
        {:error, "a task cannot depend on itself"}
      else
        {:ok, successor, predecessor}
      end
    end
  end

  defp require_new_edge(successor, predecessor) do
    case read_one(Dependency, predecessor_id: predecessor.id, successor_id: successor.id) do
      {:error, "not found"} -> :ok
      {:ok, _edge} -> {:error, "dependency already exists"}
      error -> error
    end
  end

  defp require_same_workflow(%{workflow_id: id}, %{workflow_id: id}), do: :ok

  defp require_same_workflow(_successor, _predecessor),
    do: {:error, "dependencies must stay within one workflow"}

  # Dag.validate/1 covers workflow definitions, not runtime task_dependencies
  # rows, so edge admission needs its own reachability check. A new edge
  # predecessor -> successor closes a cycle exactly when successor is already
  # reachable from predecessor by following existing predecessor edges.
  defp require_acyclic(successor, predecessor) do
    with {:ok, edges} <- Authz.read(Dependency) do
      predecessors_of =
        Enum.group_by(edges, & &1.successor_id, & &1.predecessor_id)

      if reaches?(predecessor.id, successor.id, predecessors_of, MapSet.new()) do
        {:error, "dependency would create a cycle"}
      else
        :ok
      end
    end
  end

  defp reaches?(from, target, _predecessors_of, _seen) when from == target, do: true

  defp reaches?(from, target, predecessors_of, seen) do
    if MapSet.member?(seen, from) do
      false
    else
      seen = MapSet.put(seen, from)

      predecessors_of
      |> Map.get(from, [])
      |> Enum.any?(&reaches?(&1, target, predecessors_of, seen))
    end
  end

  defp edge_json(edge, task) do
    %{
      id: edge.id,
      task: task.task_id,
      title: task.title,
      state: task.state,
      source: edge.source
    }
  end

  @inbox_states ~w(pending resolved dropped)

  defp inbox_scope(nil), do: {:ok, [state: :pending]}
  defp inbox_scope("all"), do: {:ok, []}

  defp inbox_scope(state) when state in @inbox_states,
    do: {:ok, [state: String.to_existing_atom(state)]}

  defp inbox_scope(_state),
    do: {:error, "state must be one of pending, resolved, dropped, all"}

  defp require_open_capture(%{state: :pending}), do: :ok

  defp require_open_capture(%{state: state}),
    do: {:error, "capture is already #{state}"}

  defp resolve_capture(item, to_state, attrs) do
    item
    |> Ash.Changeset.for_update(:resolve, Map.put(attrs, :to_state, to_state))
    |> Authz.update_changeset()
  end

  defp roadmap_scope(nil), do: {:ok, []}

  defp roadmap_scope(project_key) do
    with {:ok, project} <- read_one(Project, key: project_key) do
      {:ok, [project_id: project.id]}
    end
  end

  defp workflow_scope(nil, nil), do: {:ok, nil}

  defp workflow_scope(nil, roadmap_key) do
    with {:ok, roadmaps} <- Authz.read(Ash.Query.filter_input(Roadmap, key: roadmap_key)) do
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

      with {:ok, roadmaps} <- Authz.read(Ash.Query.filter_input(Roadmap, filter)) do
        case roadmaps do
          [] -> {:error, "not found"}
          roadmaps -> {:ok, Enum.map(roadmaps, & &1.id)}
        end
      end
    end
  end

  # A workflow_id is only unique within its roadmap, so the same key can exist
  # under several roadmaps. Matching on workflow_id alone would silently union
  # rows from every one of them and report a total the operator cannot explain.
  # Fail closed and name the qualified paths so the caller can scope the query.
  defp reject_ambiguous_workflow(workflows, nil), do: {:ok, workflows}

  defp reject_ambiguous_workflow(workflows, workflow_key) when length(workflows) > 1 do
    with {:ok, labels} <- roadmap_labels() do
      paths =
        workflows
        |> Enum.map(&"#{Map.get(labels, &1.roadmap_id)}/#{&1.workflow_id}")
        |> Enum.sort()
        |> Enum.join(", ")

      {:error,
       "workflow #{workflow_key} is ambiguous across #{length(workflows)} roadmaps (#{paths}); " <>
         "scope it with --project and/or --roadmap"}
    end
  end

  defp reject_ambiguous_workflow(workflows, _workflow_key), do: {:ok, workflows}

  defp roadmap_labels do
    with {:ok, projects} <- Authz.read(Project),
         {:ok, roadmaps} <- Authz.read(Roadmap) do
      project_keys = Map.new(projects, &{&1.id, &1.key})

      {:ok,
       Map.new(roadmaps, fn roadmap ->
         {roadmap.id, "#{Map.get(project_keys, roadmap.project_id)}/#{roadmap.key}"}
       end)}
    end
  end

  defp read_one(resource, filter), do: Authz.read_one(resource, filter)

  defp require_valid_id(id) do
    if TaskId.valid?(id), do: :ok, else: {:error, "invalid task ID"}
  end

  # Accept either a UUID or a friendly key. board add/list take
  # project/roadmap/workflow keys, so column, filter, and move should not
  # demand raw UUIDs for the same board.
  defp resolve_board_ref(ref) do
    if uuid?(ref) do
      {:ok, ref}
    else
      with {:ok, board} <- read_one(Board, key: ref) do
        {:ok, board.id}
      end
    end
  end

  defp resolve_column(board_id, ref) do
    if uuid?(ref) do
      read_one(BoardColumn, id: ref, board_id: board_id)
    else
      read_one(BoardColumn, key: ref, board_id: board_id)
    end
  end

  defp uuid?(value) when is_binary(value) do
    match?({:ok, _}, Ecto.UUID.cast(value))
  end

  defp uuid?(_value), do: false

  defp optional_task_type(nil), do: {:ok, nil}
  defp optional_task_type("task"), do: {:ok, :task}
  defp optional_task_type("diagnosis"), do: {:ok, :diagnosis}
  defp optional_task_type(_), do: {:error, "type must be task or diagnosis"}

  # Build the WHERE clause for task list. Every predicate here used to run in
  # Elixir after reading the whole table; expressing them as Ash filters lets
  # Postgres do the work, so --limit bounds the query rather than just the
  # response payload.
  defp task_scope_query(query, states, task_type, workflow_ids, priority, filters) do
    query
    |> then(fn q ->
      if states, do: Ash.Query.filter(q, expr(state in ^states)), else: q
    end)
    |> then(fn q ->
      if task_type, do: Ash.Query.filter(q, expr(task_type == ^task_type)), else: q
    end)
    |> then(fn q ->
      if workflow_ids, do: Ash.Query.filter(q, expr(workflow_id in ^workflow_ids)), else: q
    end)
    |> then(fn q ->
      case priority do
        nil -> q
        # "none" reaches legacy rows admitted before the priority gate.
        :none -> Ash.Query.filter(q, expr(is_nil(priority)))
        value -> Ash.Query.filter(q, expr(priority == ^value))
      end
    end)
    |> then(fn q ->
      case Map.get(filters, :label) do
        nil -> q
        label -> Ash.Query.filter(q, expr(^label in labels))
      end
    end)
    |> then(fn q ->
      case Map.get(filters, :assignee) do
        nil -> q
        assignee -> Ash.Query.filter(q, expr(^assignee in assignees))
      end
    end)
    |> then(fn q ->
      case Map.get(filters, :text) do
        nil ->
          q

        # Matches the previous case-insensitive substring search on title.
        text ->
          Ash.Query.filter(q, expr(contains(fragment("lower(?)", title), ^String.downcase(text))))
      end
    end)
  end

  # Task IDs are lexically time-ordered, so ordering by task_id is also
  # creation order and `recent` is simply its descending form.
  #
  # state and title sort by byte order under COLLATE "C", and title is
  # lowercased first, exactly reproducing the previous in-memory
  # `Enum.sort_by(&{String.downcase(&1.title), &1.task_id})`.
  #
  # Neither the database's en_US.UTF-8 collation nor a bare COLLATE "C" is
  # equivalent. en_US ignores case and punctuation on its first pass, so it
  # orders "inbox" before "in_progress"; plain COLLATE "C" is byte order, so
  # it puts every uppercase title ahead of every lowercase one ("Add G" before
  # "Add a"). Both disagree with the old behaviour, and the disagreement is
  # not cosmetic: with --limit/--offset a different comparator returns
  # *different rows* for the same window, silently repartitioning existing
  # pagination.
  defp task_sort_query(query, sort) do
    case sort do
      :recent ->
        Ash.Query.sort(query, task_id: :desc)

      :priority ->
        Ash.Query.sort(query, priority: :asc_nils_last, task_id: :asc)

      :state ->
        Ash.Query.sort(query, [
          {calc(fragment("? COLLATE \"C\"", state), type: :string), :asc},
          {:task_id, :asc}
        ])

      :title ->
        Ash.Query.sort(query, [
          {calc(fragment("lower(coalesce(?, '')) COLLATE \"C\"", title), type: :string), :asc},
          {:task_id, :asc}
        ])

      _ ->
        Ash.Query.sort(query, task_id: :asc)
    end
  end

  defp paginate_query(query, nil, nil), do: query

  defp paginate_query(query, limit, offset) do
    query
    |> then(fn q -> if offset && offset > 0, do: Ash.Query.offset(q, offset), else: q end)
    |> then(fn q -> if limit, do: Ash.Query.limit(q, limit), else: q end)
  end

  # Narrow to the workflows implied by --project/--roadmap/--workflow.
  # nil means unscoped; a list means restrict to those workflow ids.
  defp task_workflow_scope(filters) do
    project = Map.get(filters, :project)
    roadmap = Map.get(filters, :roadmap)
    workflow = Map.get(filters, :workflow)

    if is_nil(project) and is_nil(roadmap) and is_nil(workflow) do
      {:ok, nil}
    else
      with {:ok, roadmap_ids} <- workflow_scope(project, roadmap),
           filter = if(roadmap_ids, do: [roadmap_id: [in: roadmap_ids]], else: []),
           filter = if(workflow, do: [{:workflow_id, workflow} | filter], else: filter),
           {:ok, workflows} <- Authz.read(Ash.Query.filter_input(Workflow, filter)),
           {:ok, workflows} <- reject_ambiguous_workflow(workflows, workflow) do
        case workflows do
          [] -> {:error, "not found"}
          workflows -> {:ok, Enum.map(workflows, & &1.id)}
        end
      end
    end
  end

  defp optional_state(nil), do: {:ok, nil}

  defp optional_state(state) do
    case Ash.Type.cast_input(TaskState, state) do
      {:ok, state} -> {:ok, state}
      _ -> {:error, "invalid task state"}
    end
  end

  # --state accepts one state or a comma-separated set ("ready,in_progress").
  # Returns a list of stringified states, or nil when unscoped.
  defp optional_states(nil), do: {:ok, nil}

  defp optional_states(raw) do
    raw
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> case do
      [] ->
        {:error, "invalid task state"}

      parts ->
        Enum.reduce_while(parts, {:ok, []}, fn part, {:ok, acc} ->
          case optional_state(part) do
            {:ok, state} -> {:cont, {:ok, [to_string(state) | acc]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, states} -> {:ok, states |> Enum.reverse() |> Enum.uniq()}
          error -> error
        end
    end
  end

  # --priority accepts 0..5, or "none" to reach legacy rows admitted before
  # the priority gate existed (stored as NULL).
  defp optional_priority(nil), do: {:ok, nil}
  defp optional_priority("none"), do: {:ok, :none}
  defp optional_priority("unset"), do: {:ok, :none}

  defp optional_priority(raw) do
    case Integer.parse(raw) do
      {value, ""} when value >= 0 and value <= 5 -> {:ok, value}
      _ -> {:error, "priority must be 0 through 5, or none"}
    end
  end

  @sort_fields %{
    "id" => :id,
    "priority" => :priority,
    "state" => :state,
    "title" => :title,
    "created" => :created,
    "recent" => :recent
  }

  defp optional_sort(nil), do: {:ok, :id}

  defp optional_sort(raw) do
    case Map.fetch(@sort_fields, raw) do
      {:ok, field} when field in [:id, :created, :recent, :priority, :state, :title] ->
        {:ok, field}

      :error ->
        {:error,
         "sort must be one of: #{@sort_fields |> Map.keys() |> Enum.sort() |> Enum.join(", ")}"}
    end
  end

  defp optional_window(nil, _name), do: {:ok, nil}
  defp optional_window(value, _name) when is_integer(value) and value >= 0, do: {:ok, value}
  defp optional_window(_value, name), do: {:error, "#{name} must be a non-negative integer"}

  # Human-readable project/roadmap/workflow membership for each workflow row.
  defp workflow_memberships do
    with {:ok, projects} <- Authz.read(Project),
         {:ok, roadmaps} <- Authz.read(Roadmap),
         {:ok, workflows} <- Authz.read(Workflow) do
      project_keys = Map.new(projects, &{&1.id, &1.key})
      roadmap_rows = Map.new(roadmaps, &{&1.id, &1})

      {:ok,
       Map.new(workflows, fn workflow ->
         roadmap = Map.get(roadmap_rows, workflow.roadmap_id)

         {workflow.id,
          %{
            project: roadmap && Map.get(project_keys, roadmap.project_id),
            roadmap: roadmap && roadmap.key,
            workflow: workflow.workflow_id,
            workflow_name: workflow.name
          }}
       end)}
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
    |> Authz.update_changeset()
  end

  defp create_todo(task, todo_id, body) do
    # AUTHORIZATION: this CLI path resolves the request actor and all reads and
    # writes in the transaction use Authz; the query only serializes task intake.
    Repo.transaction(fn ->
      # AUTHORIZATION: covered by the actor-bound create_todo entrypoint above.
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [task.id])

      with {:ok, fresh_task} <- read_one(Task, id: task.id),
           :ok <- todo_admission_allowed(fresh_task),
           {:ok, todos} <- Authz.read(Ash.Query.filter_input(Todo, task_id: task.id)) do
        Authz.create(
          Todo,
          %{
            task_id: task.id,
            todo_id: todo_id,
            body: body,
            position: next_position(todos)
          },
          return_notifications?: true
        )
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

  # Append after the highest occupied slot rather than at length + 1.
  # remove_todo deletes without renumbering and (task_id, position) is unique,
  # so counting rows made any non-tail removal collide with a surviving row and
  # wedge the checklist permanently. Position is presentational, so gaps are
  # acceptable; uniqueness and stable ordering are what must hold.
  defp next_position([]), do: 1

  defp next_position(todos) do
    todos
    |> Enum.map(& &1.position)
    |> Enum.max()
    |> Kernel.+(1)
  end

  defp todo_admission_allowed(%{state: state}) when state in [:completed, :cancelled],
    do: {:error, "cannot add TODO to terminal task"}

  defp todo_admission_allowed(_task), do: :ok

  defp task_json(task) do
    case workflow_memberships() do
      {:ok, memberships} -> task_json(task, memberships)
      {:error, error} -> raise "cannot resolve task hierarchy: #{inspect(error)}"
    end
  end

  defp task_json(task, memberships) do
    membership = Map.get(memberships, task.workflow_id)

    %{
      id: task.task_id,
      type: task.task_type,
      title: task.title,
      description: task.description,
      project: membership && membership.project,
      roadmap: membership && membership.roadmap,
      workflow: membership && membership.workflow,
      workflow_name: membership && membership.workflow_name,
      definition_of_done: task.definition_of_done,
      artifact_requirements: task.artifact_requirements,
      artifact_receipts: task.artifact_receipts,
      sop_gate_required: task.sop_gate_required,
      sop_id: task.sop_id,
      sop_path: task.sop_path,
      sop_digest: task.sop_digest,
      # Exposed because the vault's write gate re-implements the same rule and
      # reads this JSON; without the version it could only apply the digest
      # branch and would refuse tasks SpruceGoose considers valid.
      sop_version: task.sop_version,
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

  defp inbox_json(item),
    do: %{
      id: item.capture_id,
      body: item.body,
      state: item.state,
      resolution_reason: item.resolution_reason,
      promoted_task_id: item.promoted_task_id,
      resolved_at: item.resolved_at
    }

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

  defp require_distinct_artifact_verifier(task) do
    with {:ok, scope} <- SpruceGoose.Actors.Scope.of(task) do
      if SpruceGoose.Actors.Scope.holds?(Authz.actor!(), :operator, scope),
        do: {:error, "artifact verifier must not also hold operator over the task"},
        else: :ok
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
