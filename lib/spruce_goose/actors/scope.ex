defmodule SpruceGoose.Actors.Scope do
  @moduledoc """
  What project a thing belongs to, and whether an actor holds a role over it.

  Scope resolution is a SQL walk up to `projects` rather than a preloaded
  relationship graph: the check runs inside a policy, where the record is loaded
  but its ancestors are not, and this codebase already resolves across tables
  inside a check — see `SpruceGoose.Workflows.Task.validate_board_scope/4`.

  Grants are read with `authorize?: false`. A permission check may never be
  subject to the permissions it decides.
  """

  require Ash.Query

  alias SpruceGoose.Actors.{Actor, Grant}
  alias SpruceGoose.Derivations.Permit
  alias SpruceGoose.Repo

  alias SpruceGoose.Workflows.{
    Board,
    BoardColumn,
    BlueprintRevision,
    Dependency,
    InboxItem,
    Project,
    Revision,
    Roadmap,
    SavedFilter,
    Task,
    Todo,
    TodoDependency,
    Workflow
  }

  # Each entry answers "given this row's own id, which project key owns it".
  @by_id %{
    Roadmap =>
      "SELECT p.key FROM roadmaps r JOIN projects p ON p.id = r.project_id WHERE r.id = $1",
    Workflow => """
    SELECT p.key FROM workflows w
    JOIN roadmaps r ON r.id = w.roadmap_id
    JOIN projects p ON p.id = r.project_id
    WHERE w.id = $1
    """,
    Task => """
    SELECT p.key FROM workflow_tasks t
    JOIN workflows w ON w.id = t.workflow_id
    JOIN roadmaps r ON r.id = w.roadmap_id
    JOIN projects p ON p.id = r.project_id
    WHERE t.id = $1
    """,
    Board => """
    SELECT p.key FROM boards b
    JOIN workflows w ON w.id = b.workflow_id
    JOIN roadmaps r ON r.id = w.roadmap_id
    JOIN projects p ON p.id = r.project_id
    WHERE b.id = $1
    """,
    BoardColumn => """
    SELECT p.key FROM board_columns c
    JOIN boards b ON b.id = c.board_id
    JOIN workflows w ON w.id = b.workflow_id
    JOIN roadmaps r ON r.id = w.roadmap_id
    JOIN projects p ON p.id = r.project_id
    WHERE c.id = $1
    """,
    SavedFilter => """
    SELECT p.key FROM saved_filters f
    JOIN boards b ON b.id = f.board_id
    JOIN workflows w ON w.id = b.workflow_id
    JOIN roadmaps r ON r.id = w.roadmap_id
    JOIN projects p ON p.id = r.project_id
    WHERE f.id = $1
    """,
    Todo => """
    SELECT p.key FROM task_todos td
    JOIN workflow_tasks t ON t.id = td.task_id
    JOIN workflows w ON w.id = t.workflow_id
    JOIN roadmaps r ON r.id = w.roadmap_id
    JOIN projects p ON p.id = r.project_id
    WHERE td.id = $1
    """,
    Dependency => """
    SELECT p.key FROM task_dependencies d
    JOIN workflow_tasks t ON t.id = d.successor_id
    JOIN workflows w ON w.id = t.workflow_id
    JOIN roadmaps r ON r.id = w.roadmap_id
    JOIN projects p ON p.id = r.project_id
    WHERE d.id = $1
    """,
    TodoDependency => """
    SELECT p.key FROM task_todo_dependencies td
    JOIN workflow_tasks t ON t.id = td.task_id
    JOIN workflows w ON w.id = t.workflow_id
    JOIN roadmaps r ON r.id = w.roadmap_id
    JOIN projects p ON p.id = r.project_id
    WHERE td.id = $1
    """,
    BlueprintRevision => """
    SELECT p.key FROM workflow_blueprint_revisions br
    JOIN projects p ON p.id = br.project_id
    WHERE br.id = $1
    """,
    Permit => """
    SELECT p.key FROM derivation_permits dp
    JOIN workflow_tasks t ON t.id = dp.task_id
    JOIN workflows w ON w.id = t.workflow_id
    JOIN roadmaps r ON r.id = w.roadmap_id
    JOIN projects p ON p.id = r.project_id
    WHERE dp.id = $1
    """
  }

  # For a create there is no row yet, so scope comes from the parent the
  # changeset names. Project creates are absent on purpose: a project cannot be
  # scoped to itself before it exists, so creating one requires a global grant.
  @by_parent %{
    Roadmap => {:project_id, Project},
    Workflow => {:roadmap_id, Roadmap},
    Task => {:workflow_id, Workflow},
    Board => {:workflow_id, Workflow},
    BoardColumn => {:board_id, Board},
    SavedFilter => {:board_id, Board},
    Todo => {:task_id, Task},
    BlueprintRevision => {:project_id, Project},
    Permit => {:task_id, Task}
  }

  # The relationship path from each resource to the owning project key, used to
  # turn a project-scoped read grant into a filter rather than a refusal.
  @read_paths %{
    Project => [:key],
    Roadmap => [:project, :key],
    Workflow => [:roadmap, :project, :key],
    Task => [:workflow, :roadmap, :project, :key],
    Board => [:workflow, :roadmap, :project, :key],
    BoardColumn => [:board, :workflow, :roadmap, :project, :key],
    SavedFilter => [:board, :workflow, :roadmap, :project, :key],
    Todo => [:task, :workflow, :roadmap, :project, :key],
    Dependency => [:successor, :workflow, :roadmap, :project, :key],
    TodoDependency => [:successor, :task, :workflow, :roadmap, :project, :key],
    Revision => [:project_key],
    BlueprintRevision => [:project, :key],
    Permit => [:task, :workflow, :roadmap, :project, :key]
  }

  @doc """
  The relationship path from `resource` to its owning project key, or `nil` if
  the resource has no project (the inbox holds pre-triage captures).
  """
  def read_path(resource), do: Map.get(@read_paths, resource)

  @doc """
  Resolve the scope a subject falls under.

  Returns `{:ok, {:project, key}}`, `{:ok, :global}` for things that belong to
  no project, or an error when the scope cannot be determined — which is
  refused rather than defaulted, since a scope that cannot be established is
  not a scope anyone was granted.
  """
  def of(%Ash.Changeset{action_type: :create} = changeset), do: create_scope(changeset)
  def of(%Ash.Changeset{data: data}), do: of(data)
  def of(%Project{key: key}), do: {:ok, {:project, key}}
  def of(%InboxItem{}), do: {:ok, :global}
  def of(%Revision{project_key: nil}), do: {:ok, :global}
  def of(%Revision{project_key: key}), do: {:ok, {:project, key}}

  def of(%module{id: id}) when is_binary(id) do
    case Map.fetch(@by_id, module) do
      {:ok, sql} -> query_key(sql, id, module)
      :error -> {:error, "no scope is defined for #{inspect(module)}"}
    end
  end

  def of(other), do: {:error, "cannot determine scope for #{inspect(other)}"}

  defp create_scope(%Ash.Changeset{resource: Project}), do: {:ok, :global}
  defp create_scope(%Ash.Changeset{resource: InboxItem}), do: {:ok, :global}

  defp create_scope(%Ash.Changeset{resource: Revision} = changeset) do
    case Ash.Changeset.get_attribute(changeset, :project_key) do
      nil -> {:ok, :global}
      key -> {:ok, {:project, key}}
    end
  end

  defp create_scope(%Ash.Changeset{resource: Dependency} = changeset),
    do: parent_scope(changeset, :successor_id, Task)

  defp create_scope(%Ash.Changeset{resource: TodoDependency} = changeset),
    do: parent_scope(changeset, :task_id, Task)

  defp create_scope(%Ash.Changeset{resource: resource} = changeset) do
    case Map.fetch(@by_parent, resource) do
      {:ok, {attribute, parent}} -> parent_scope(changeset, attribute, parent)
      :error -> {:error, "no scope is defined for creating #{inspect(resource)}"}
    end
  end

  defp parent_scope(changeset, attribute, Project) do
    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil -> {:error, "#{attribute} is required before scope can be determined"}
      id -> query_key("SELECT key FROM projects WHERE id = $1", id, Project)
    end
  end

  defp parent_scope(changeset, attribute, parent) do
    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil -> {:error, "#{attribute} is required before scope can be determined"}
      id -> query_key(Map.fetch!(@by_id, parent), id, parent)
    end
  end

  defp query_key(sql, id, module) do
    # AUTHORIZATION: internal grant-scope lookup used by the authorization check itself.
    case Ecto.Adapters.SQL.query!(Repo, sql, [Ecto.UUID.dump!(id)]).rows do
      [[key]] -> {:ok, {:project, key}}
      _ -> {:error, "#{inspect(module)} #{id} has no owning project"}
    end
  end

  @doc """
  Does `actor` hold `role` over `scope`?

  A global grant covers every scope. Any grant implies `:reader` within its own
  scope: an operator that cannot read the task it is operating on is not a
  coherent grant.
  """
  def holds?(actor, role, scope) do
    actor
    |> grants()
    |> Enum.any?(&covers?(&1, role, scope))
  end

  @doc "Project keys this actor can read, or `:global` if it reads everything."
  def readable_projects(actor) do
    grants = grants(actor)

    if Enum.any?(grants, &(&1.scope == Grant.global())) do
      :global
    else
      grants
      |> Enum.flat_map(fn grant ->
        case Grant.parse_scope(grant.scope) do
          {:ok, {:project, key}} -> [key]
          _ -> []
        end
      end)
      |> Enum.uniq()
    end
  end

  @doc "Every grant held, as `{role, scope}` pairs — for `whoami` and error messages."
  def summary(actor) do
    actor
    |> grants()
    |> Enum.map(&%{role: &1.role, scope: &1.scope, granted_by: &1.granted_by})
    |> Enum.sort_by(&{to_string(&1.role), &1.scope})
  end

  defp grants(%Actor{id: id}) do
    Grant
    |> Ash.Query.filter_input(actor_id: id)
    |> Ash.read!(authorize?: false)
  end

  defp grants(_actor), do: []

  defp covers?(grant, role, scope) do
    role_matches?(grant.role, role) and scope_matches?(grant.scope, scope)
  end

  defp role_matches?(held, held), do: true
  defp role_matches?(_held, :reader), do: true
  defp role_matches?(_held, _wanted), do: false

  defp scope_matches?(held, _scope) when held == "*", do: true
  defp scope_matches?(_held, :global), do: false
  defp scope_matches?(held, {:project, key}), do: held == "project:" <> key
end
