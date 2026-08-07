defmodule SpruceGoose.Revise do
  @moduledoc """
  Governed revision of a SpruceGoose entity: a TOML sparse patch, proposed
  once and applied only after an explicit sign-off.

  ## Why two steps

  `add` / `rename` / `remove` are the only mutations the CLI has ever offered,
  so changing what a roadmap, workflow, or task *says* has had to happen out of
  band. That is the same ungoverned-write problem the vault's
  `vault-write-authorization.py` exists to make fail loudly, and the answer here
  is the same one: bind the change to a task identity and a verified SOP digest.

  Approval additionally requires the approver to quote back the SHA-256 that
  `show` printed. A revision therefore cannot be approved without having been
  looked at, and the bytes that were reviewed are the bytes that apply — the
  TOML body is stored on the row, so editing or deleting the source file after
  proposing changes nothing.

  ## Honest boundary

  This is an integrity control, not a confidentiality one. The CLI socket, the
  Postgres store, and the agent all run as the same host user, so a determined
  local process can bypass every check here by writing rows directly. It exists
  so that ungoverned revisions fail loudly by default and so that each applied
  change carries a durable record of who signed it off and against what bytes.
  """

  require Ash.Query

  alias SpruceGoose.Actors.Scope
  alias SpruceGoose.{Authz, PrefixedId, Repo, SopGate, TaskId}

  alias SpruceGoose.Workflows.{
    Board,
    BoardColumn,
    Definition,
    Project,
    Revision,
    Roadmap,
    SavedFilter,
    Task,
    Workflow
  }

  @prefix "rev"

  # Matches the socket plug's body ceiling. A revision that does not fit is a
  # rewrite, not a revision.
  @max_source_bytes 65_536

  @document_keys ~w(target expect_lock_version reason change)

  # Identity fields are excluded on purpose: the vault's Markdown references
  # entities by these (`roadmap:agent-work-authority-routing`), so revising one
  # silently breaks every link pointing at it. Renaming an identity is a
  # migration, not a revision.
  @identity_keys ~w(key workflow_id task_id id)

  @revisable %{
    roadmap: ~w(name),
    workflow: ~w(name definition),
    task: ~w(title description definition_of_done runner input),
    board: ~w(name),
    column: ~w(name position),
    filter: ~w(name criteria)
  }

  @states ~w(pending applied withdrawn)

  # -- propose ---------------------------------------------------------------

  def propose(path) do
    proposer = Authz.actor!()

    with {:ok, body} <- read_source(path),
         {:ok, document} <- decode_document(body),
         {:ok, ref, expect, reason, change} <- validate_document(document),
         {:ok, kind, record} <- resolve_target(ref),
         :ok <- validate_change(kind, change),
         :ok <- require_lock_version(record, expect),
         {:ok, _input} <- build_input(kind, change),
         {:ok, project_key} <- project_key(record),
         {:ok, revision} <-
           Authz.create(Revision, %{
             revision_id: PrefixedId.generate(@prefix),
             target_kind: kind,
             target_id: record.id,
             target_ref: ref,
             project_key: project_key,
             expect_lock_version: expect,
             change: change,
             reason: reason,
             source_path: path,
             source_body: body,
             source_digest: digest(body),
             proposed_by: proposer.name
           }) do
      {:ok, Map.put(revision_json(revision), :diff, diff(kind, record, change))}
    end
  end

  # The revision's scope is fixed at proposal, so the policy that guards its
  # approval cannot shift under it later.
  defp project_key(record) do
    case Scope.of(record) do
      {:ok, {:project, key}} -> {:ok, key}
      {:ok, :global} -> {:ok, nil}
      {:error, message} -> {:error, message}
    end
  end

  # -- read ------------------------------------------------------------------

  def list(state, target_ref) do
    with {:ok, filter} <- list_filter(state, target_ref),
         {:ok, revisions} <- Authz.read(Ash.Query.filter_input(Revision, filter)) do
      {:ok,
       %{
         revisions:
           revisions
           |> Enum.sort_by(& &1.revision_id)
           |> Enum.map(&revision_json/1)
       }}
    end
  end

  def show(revision_id) do
    with {:ok, revision} <- fetch_revision(revision_id) do
      diff =
        case resolve_target(revision.target_ref) do
          {:ok, kind, record} -> diff(kind, record, revision.change)
          # A target removed after proposing still has a viewable proposal; the
          # approve gate is where its absence becomes a refusal.
          {:error, _reason} -> nil
        end

      {:ok,
       revision
       |> revision_json()
       |> Map.merge(%{source_body: revision.source_body, diff: diff})}
    end
  end

  # -- sign-off --------------------------------------------------------------

  def approve(revision_id, task_id, digest, self?) do
    approver = Authz.actor!()

    with {:ok, digest} <- normalize_digest(digest),
         {:ok, revision} <- fetch_revision(revision_id),
         :ok <- require_pending(revision),
         :ok <- require_digest(revision, digest),
         :ok <- require_approver_role(revision, approver),
         :ok <- require_distinct_signer(revision, approver, self?),
         {:ok, task} <- authorize(task_id),
         {:ok, kind, record} <- resolve_target(revision.target_ref),
         :ok <- require_same_target(revision, record),
         :ok <- require_lock_version(record, revision.expect_lock_version),
         {:ok, input} <- build_input(kind, revision.change) do
      # The entity and the sign-off record land together or not at all: an
      # applied change with no record of who approved it is exactly the
      # ungoverned write this verb exists to prevent.
      transaction(fn ->
        with {:ok, updated, entity_notices} <-
               Authz.update(record, input, action: :revise, return_notifications?: true),
             {:ok, applied, revision_notices} <-
               Authz.update(
                 revision,
                 %{
                   approved_by: approver.name,
                   authorizing_task_id: task.task_id,
                   applied_lock_version: updated.lock_version,
                   self_approved: revision.proposed_by == approver.name
                 },
                 action: :approve,
                 return_notifications?: true
               ) do
          {:ok, {revision_json(applied), entity_notices ++ revision_notices}}
        end
      end)
      |> case do
        {:ok, {json, notifications}} ->
          # Notifications cannot be delivered from inside the transaction; Ash
          # hands them back so they fire once the commit is real.
          Ash.Notifier.notify(notifications)
          {:ok, json}

        error ->
          error
      end
    end
  end

  def withdraw(revision_id, reason) do
    with {:ok, reason} <- require_reason(reason),
         {:ok, revision} <- fetch_revision(revision_id),
         :ok <- require_pending(revision),
         {:ok, revision} <-
           Authz.update(revision, %{withdrawn_reason: reason}, action: :withdraw) do
      {:ok, revision_json(revision)}
    end
  end

  # -- source ----------------------------------------------------------------

  defp read_source(path) when is_binary(path) do
    if Path.type(path) == :absolute do
      read_bounded(path)
    else
      {:error,
       "--file must be an absolute path: the CLI service reads it, not your shell, " <>
         "so a relative path resolves against the service working directory"}
    end
  end

  defp read_source(_path), do: {:error, "--file is required"}

  defp read_bounded(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_source_bytes ->
        case File.read(path) do
          {:ok, body} -> {:ok, body}
          {:error, reason} -> {:error, "cannot read #{path}: #{posix(reason)}"}
        end

      {:ok, %File.Stat{type: :regular}} ->
        {:error, "revision file exceeds #{@max_source_bytes} bytes"}

      {:ok, _stat} ->
        {:error, "#{path} is not a regular file"}

      {:error, reason} ->
        {:error, "cannot read #{path}: #{posix(reason)}"}
    end
  end

  defp posix(reason), do: reason |> :file.format_error() |> List.to_string()

  defp decode_document(body) do
    case Toml.decode(body) do
      {:ok, document} when is_map(document) -> {:ok, document}
      {:error, {:invalid_toml, message}} -> {:error, "invalid TOML: #{message}"}
      {:error, message} when is_binary(message) -> {:error, "invalid TOML: #{message}"}
      {:error, reason} -> {:error, "invalid TOML: #{inspect(reason)}"}
    end
  end

  defp validate_document(document) do
    with :ok <- require_known_keys(Map.keys(document), @document_keys, "revision document"),
         {:ok, ref} <- require_string(document, "target"),
         {:ok, expect} <- require_integer(document, "expect_lock_version"),
         {:ok, reason} <- require_string(document, "reason"),
         {:ok, change} <- require_change(document) do
      {:ok, ref, expect, reason, change}
    end
  end

  defp require_string(document, key) do
    case Map.get(document, key) do
      value when is_binary(value) ->
        if String.trim(value) == "",
          do: {:error, "#{key} must not be blank"},
          else: {:ok, value}

      nil ->
        {:error, "#{key} is required"}

      _other ->
        {:error, "#{key} must be a string"}
    end
  end

  defp require_integer(document, key) do
    case Map.get(document, key) do
      value when is_integer(value) -> {:ok, value}
      nil -> {:error, "#{key} is required"}
      _other -> {:error, "#{key} must be an integer"}
    end
  end

  defp require_change(document) do
    case Map.get(document, "change") do
      change when is_map(change) and map_size(change) > 0 -> {:ok, change}
      change when is_map(change) -> {:error, "[change] must set at least one field"}
      nil -> {:error, "[change] is required"}
      _other -> {:error, "[change] must be a table"}
    end
  end

  defp require_known_keys(keys, allowed, label) do
    case keys -- allowed do
      [] -> :ok
      unknown -> {:error, "#{label} has unsupported keys: #{Enum.join(Enum.sort(unknown), ", ")}"}
    end
  end

  # -- targets ---------------------------------------------------------------

  defp resolve_target("roadmap:" <> ref) do
    case String.split(ref, "/") do
      [project_key, roadmap_key] when project_key != "" and roadmap_key != "" ->
        with {:ok, project} <- fetch_one(Project, key: project_key),
             {:ok, roadmap} <- fetch_one(Roadmap, project_id: project.id, key: roadmap_key) do
          {:ok, :roadmap, roadmap}
        end

      _other ->
        {:error, "roadmap target must be roadmap:PROJECT/ROADMAP"}
    end
  end

  defp resolve_target("workflow:" <> ref) do
    case String.split(ref, "/") do
      [project_key, roadmap_key, workflow_key]
      when project_key != "" and roadmap_key != "" and workflow_key != "" ->
        with {:ok, project} <- fetch_one(Project, key: project_key),
             {:ok, roadmap} <- fetch_one(Roadmap, project_id: project.id, key: roadmap_key),
             {:ok, workflow} <-
               fetch_one(Workflow, roadmap_id: roadmap.id, workflow_id: workflow_key) do
          {:ok, :workflow, workflow}
        end

      _other ->
        {:error, "workflow target must be workflow:PROJECT/ROADMAP/WORKFLOW_ID"}
    end
  end

  defp resolve_target("task:" <> task_id) do
    if TaskId.valid?(task_id) do
      with {:ok, task} <- fetch_one(Task, task_id: task_id), do: {:ok, :task, task}
    else
      {:error, "task target must be task:tsk-YYYYMMDDTHHMMSSZ-8hex"}
    end
  end

  defp resolve_target("board:" <> id), do: by_uuid(:board, Board, id)
  defp resolve_target("column:" <> id), do: by_uuid(:column, BoardColumn, id)
  defp resolve_target("filter:" <> id), do: by_uuid(:filter, SavedFilter, id)

  defp resolve_target(_ref) do
    {:error,
     "target must name one of: " <>
       (@revisable |> Map.keys() |> Enum.map(&"#{&1}:") |> Enum.sort() |> Enum.join(" "))}
  end

  defp by_uuid(kind, resource, id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        with {:ok, record} <- fetch_one(resource, id: uuid), do: {:ok, kind, record}

      :error ->
        {:error, "#{kind} target must be #{kind}:UUID"}
    end
  end

  defp require_same_target(%{target_id: target_id}, %{id: id}) when target_id == id, do: :ok

  defp require_same_target(_revision, _record),
    do: {:error, "the target this revision names is not the record it was proposed against"}

  defp require_lock_version(%{lock_version: actual}, expect) when actual == expect, do: :ok

  defp require_lock_version(%{lock_version: actual}, expect) do
    {:error,
     "target is at lock_version #{actual}, not the #{expect} this revision expects; " <>
       "it changed since the proposal, so re-propose against the current state"}
  end

  # -- change ----------------------------------------------------------------

  defp validate_change(kind, change) do
    allowed = Map.fetch!(@revisable, kind)
    keys = Map.keys(change)

    case Enum.filter(keys, &(&1 in @identity_keys)) do
      [] -> require_known_keys(keys, allowed, "[change] for a #{kind}")
      [first | _] -> {:error, "#{first} identifies the #{kind} and cannot be revised"}
    end
  end

  defp build_input(kind, change) do
    Enum.reduce_while(change, {:ok, %{}}, fn {key, value}, {:ok, input} ->
      case cast(kind, key, value) do
        {:ok, cast} -> {:cont, {:ok, Map.put(input, String.to_existing_atom(key), cast)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp cast(:workflow, "definition", value) when is_map(value) do
    case Definition.parse(value) do
      {:ok, definition} -> {:ok, definition}
      {:error, error} -> {:error, error}
    end
  end

  defp cast(:workflow, "definition", _value),
    do: {:error, "definition must be a table"}

  defp cast(_kind, key, value) when key in ~w(input criteria) do
    if is_map(value), do: {:ok, value}, else: {:error, "#{key} must be a table"}
  end

  defp cast(_kind, "position", value) do
    if is_integer(value), do: {:ok, value}, else: {:error, "position must be an integer"}
  end

  defp cast(_kind, key, value) do
    if is_binary(value), do: {:ok, value}, else: {:error, "#{key} must be a string"}
  end

  defp diff(kind, record, change) do
    Map.new(change, fn {key, after_value} ->
      {key, %{before: before_value(kind, record, key), after: after_value}}
    end)
  end

  defp before_value(:workflow, record, "definition"), do: definition_json(record.definition)

  defp before_value(_kind, record, key),
    do: Map.get(record, String.to_existing_atom(key))

  defp definition_json(nil), do: nil

  defp definition_json(definition) do
    %{
      schema_version: definition.schema_version,
      tasks:
        Enum.map(definition.tasks, fn task ->
          %{id: task.id, kind: task.kind, depends_on: task.depends_on, input: task.input}
        end)
    }
  end

  # -- authorization ---------------------------------------------------------

  # Deliberately the same rule vault-write-authorization.py enforces: an
  # in-progress task carrying a current Systemwide SOP acknowledgment. Keeping
  # one rule in two places is how they drift, so this defers to SopGate rather
  # than restating the digest check.
  defp authorize(task_id) do
    with :ok <- require_task_id(task_id),
         {:ok, task} <- fetch_one(Task, task_id: task_id),
         :ok <- require_in_progress(task),
         :ok <- require_sop_gate(task),
         :ok <- SopGate.verify(task) do
      {:ok, task}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      error -> error
    end
  end

  defp require_task_id(task_id) do
    cond do
      not is_binary(task_id) or task_id == "" ->
        {:error, "approval requires --task naming the SpruceGoose task that authorizes it"}

      not TaskId.valid?(task_id) ->
        {:error, "invalid task ID"}

      true ->
        :ok
    end
  end

  defp require_in_progress(%{state: :in_progress}), do: :ok

  defp require_in_progress(%{task_id: task_id, state: state}) do
    {:error,
     "task #{task_id} is #{state}; approval requires an in_progress task. " <>
       "Run: sprucegoose task start #{task_id}"}
  end

  # SopGate.verify/1 returns :ok for an ungated task, so the gate flag is
  # checked here rather than relying on verify to refuse it.
  defp require_sop_gate(%{sop_gate_required: true}), do: :ok

  defp require_sop_gate(%{task_id: task_id}),
    do:
      {:error,
       "task #{task_id} does not carry the Systemwide SOP gate; " <>
         "grandfathered records may not approve revisions"}

  defp require_pending(%{state: :pending}), do: :ok
  defp require_pending(%{state: state}), do: {:error, "revision is already #{state}"}

  defp require_digest(%{source_digest: expected}, digest) when expected == digest, do: :ok

  defp require_digest(_revision, _digest),
    do:
      {:error,
       "--digest does not match this revision; quote back the digest that `revise show` printed"}

  defp normalize_digest(digest) when is_binary(digest) do
    normalized = digest |> String.trim() |> String.downcase()

    if Regex.match?(~r/\A[0-9a-f]{64}\z/, normalized),
      do: {:ok, normalized},
      else: {:error, "--digest must be a SHA-256 hex digest"}
  end

  defp normalize_digest(_digest),
    do: {:error, "approval requires --digest, the SHA-256 that `revise show` printed"}

  defp require_reason(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:error, "a withdrawal reason is required"}
      byte_size(trimmed) > 2_000 -> {:error, "a withdrawal reason must be at most 2000 bytes"}
      true -> {:ok, trimmed}
    end
  end

  defp require_reason(_value), do: {:error, "a withdrawal reason is required"}

  # The Ash policy on `Revision.approve` is what actually enforces this; the
  # check is repeated here only so the refusal names the missing grant instead
  # of the self-approval rule, which would be a true but less useful answer for
  # an actor that was never going to be allowed either way.
  defp require_approver_role(revision, approver) do
    scope =
      case revision.project_key do
        nil -> :global
        key -> {:project, key}
      end

    if Scope.holds?(approver, :approver, scope) do
      :ok
    else
      {:error,
       "#{approver.name} does not hold approver on #{scope_label(scope)}. " <>
         "Ask an admin for `grant add #{approver.name} --role approver " <>
         "--scope #{scope_label(scope)}`, or have an existing approver sign this off"}
    end
  end

  defp article(:agent), do: "an"
  defp article(_kind), do: "a"

  defp scope_label(:global), do: "*"
  defp scope_label({:project, key}), do: "project:#{key}"

  # Two signatures on one change is the point of a sign-off, so the default is
  # to refuse your own. `--self` is the exception a single-operator fleet needs
  # — and it is deliberately unavailable to agents: an agent proposing and
  # approving in one breath is not a review, it is a loop closing on itself.
  defp require_distinct_signer(%{proposed_by: proposer}, %{name: name}, _self?)
       when proposer != name,
       do: :ok

  defp require_distinct_signer(_revision, %{kind: :human}, true), do: :ok

  defp require_distinct_signer(_revision, %{kind: :human, name: name}, _self?) do
    {:error,
     "#{name} proposed this revision. Have another approver sign it off, or pass " <>
       "--self to record that you approved your own proposal"}
  end

  defp require_distinct_signer(_revision, %{kind: kind, name: name}, _self?) do
    {:error,
     "#{name} proposed this revision and is #{article(kind)} #{kind}; only a human " <>
       "may approve their own proposal. Have another approver sign it off"}
  end

  # -- plumbing --------------------------------------------------------------

  defp list_filter(state, target_ref) do
    with {:ok, filter} <- state_filter(state) do
      case target_ref do
        nil -> {:ok, filter}
        ref when is_binary(ref) -> {:ok, Keyword.put(filter, :target_ref, ref)}
      end
    end
  end

  defp state_filter(nil), do: {:ok, [state: :pending]}
  defp state_filter("all"), do: {:ok, []}

  defp state_filter(state) when state in @states,
    do: {:ok, [state: String.to_existing_atom(state)]}

  defp state_filter(_state),
    do: {:error, "state must be one of #{Enum.join(@states, ", ")}, all"}

  defp fetch_revision(revision_id) do
    if PrefixedId.valid?(@prefix, revision_id) do
      fetch_one(Revision, revision_id: revision_id)
    else
      {:error, "invalid revision ID"}
    end
  end

  defp fetch_one(resource, filter) do
    Authz.read_one(resource, filter)
  end

  defp transaction(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp revision_json(revision) do
    %{
      revision: revision.revision_id,
      target_kind: revision.target_kind,
      target: revision.target_ref,
      project_key: revision.project_key,
      state: revision.state,
      digest: revision.source_digest,
      expect_lock_version: revision.expect_lock_version,
      change: revision.change,
      reason: revision.reason,
      source_path: revision.source_path,
      proposed_by: revision.proposed_by,
      proposed_at: revision.proposed_at,
      approved_by: revision.approved_by,
      approved_at: revision.approved_at,
      authorizing_task: revision.authorizing_task_id,
      applied_lock_version: revision.applied_lock_version,
      self_approved: revision.self_approved,
      withdrawn_reason: revision.withdrawn_reason
    }
  end
end
