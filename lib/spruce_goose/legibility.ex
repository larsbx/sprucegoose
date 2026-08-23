defmodule SpruceGoose.Legibility do
  @moduledoc "Read-only human and machine projections of SpruceGoose authority."

  alias SpruceGoose.Authz
  alias SpruceGoose.Workflows.Project

  @archive_readme """
  # SpruceGoose Legible Archive

  Generated read-only from SpruceGoose/Ash authority. Do not edit this tree as
  input, and do not treat it as a source of truth.

  PostgreSQL remains the sole live authority for task state. Every file here is
  a projection produced by `sprucegoose project materialize`. The generator is
  deterministic: rebuilding from unchanged authority produces byte-identical
  files, so any diff is either a real authority change or a bug in the
  generator. It is never a merge to resolve by hand.

  Recover from drift by regenerating, never by editing.

  ## Layout

  ```
  projects/<project-key>/snapshot.json   structured projection
  projects/<project-key>/README.md       human-readable projection
  projects/<project-key>/graph.dot       Graphviz task graph
  ```
  """

  @doc "Render one authorized project as stable JSON data, Markdown, and DOT."
  def project(project_key) do
    with {:ok, project} <- Authz.read_one(Project, key: project_key),
         {:ok, loaded} <-
           Ash.load(project, [:blueprint_revisions, roadmaps: [workflows: [:tasks]]],
             actor: Authz.actor!(),
             authorize?: true
           ) do
      snapshot = snapshot(loaded)
      {:ok, %{snapshot: snapshot, markdown: markdown(snapshot), dot: dot(snapshot)}}
    end
  end

  @doc """
  Write authorized project projections into the configured archive root.

  The destination is deliberately not a parameter. This runs inside the service
  on the authority host, so accepting a caller-supplied path would let any CLI
  argument choose where the service writes as its own user. The root comes from
  `:legible_archive_root` configuration instead, and callers name only projects.

  Writes only the generated tree; it never reads the target back as input and
  performs no Git operations. Rendering is deterministic, so materializing
  unchanged authority twice produces byte-identical files.
  """
  def materialize(project_keys) when is_list(project_keys) do
    with {:ok, root} <- archive_root(),
         :ok <- File.mkdir_p(Path.join(root, "projects")),
         :ok <- File.write(Path.join(root, "README.md"), @archive_readme),
         {:ok, written} <- materialize_projects(Enum.sort(project_keys), root) do
      {:ok, %{root: root, projects: written}}
    end
  end

  defp archive_root do
    case Application.get_env(:spruce_goose, :legible_archive_root) do
      root when is_binary(root) ->
        trimmed = String.trim(root)

        cond do
          trimmed == "" ->
            {:error, "legible archive root is empty"}

          not (trimmed =~ ~r|\A/|) ->
            {:error, "legible archive root must be an absolute path"}

          true ->
            {:ok, Path.expand(trimmed)}
        end

      _ ->
        {:error, "legible archive root is not configured"}
    end
  end

  defp materialize_projects(project_keys, root) do
    Enum.reduce_while(project_keys, {:ok, []}, fn key, {:ok, acc} ->
      case materialize_project(key, root) do
        {:ok, entry} -> {:cont, {:ok, acc ++ [entry]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp materialize_project(project_key, root) do
    with {:ok, view} <- project(project_key),
         directory = Path.join([root, "projects", project_key]),
         :ok <- File.mkdir_p(directory),
         files = archive_files(view),
         :ok <- write_files(directory, files) do
      {:ok, %{project: project_key, files: Enum.map(files, &elem(&1, 0))}}
    end
  end

  # Encoded with sorted map keys so a rebuild cannot reorder JSON and present a
  # spurious diff.
  defp archive_files(view) do
    [
      {"README.md", view.markdown <> "\n"},
      {"graph.dot", view.dot},
      {"snapshot.json", Jason.encode!(view.snapshot, pretty: true, maps: :strict) <> "\n"}
    ]
  end

  defp write_files(directory, files) do
    Enum.reduce_while(files, :ok, fn {name, contents}, :ok ->
      case File.write(Path.join(directory, name), contents) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp snapshot(project) do
    %{
      schema_version: 1,
      project: %{key: project.key, name: project.name},
      blueprint_revisions:
        project.blueprint_revisions
        |> Enum.sort_by(& &1.revision_id)
        |> Enum.map(&blueprint_snapshot/1),
      roadmaps:
        project.roadmaps
        |> Enum.sort_by(& &1.key)
        |> Enum.map(&roadmap_snapshot/1)
    }
  end

  defp roadmap_snapshot(roadmap) do
    %{
      key: roadmap.key,
      name: roadmap.name,
      workflows:
        roadmap.workflows
        |> Enum.sort_by(& &1.workflow_id)
        |> Enum.map(fn workflow ->
          %{
            id: workflow.workflow_id,
            name: workflow.name,
            tasks:
              workflow.tasks
              |> Enum.sort_by(& &1.task_id)
              |> Enum.map(&task_snapshot/1)
          }
        end)
    }
  end

  defp task_snapshot(task) do
    %{
      id: task.task_id,
      title: task.title,
      type: task.task_type,
      state: task.state,
      priority: task.priority,
      definition_of_done: task.definition_of_done
    }
  end

  defp blueprint_snapshot(revision) do
    %{
      id: revision.revision_id,
      repository: revision.repository,
      commit: revision.source_commit,
      tree: revision.source_tree,
      path: revision.source_path,
      digest: revision.manifest_digest,
      schema_version: revision.schema_version
    }
  end

  defp markdown(snapshot) do
    sections =
      Enum.map_join(snapshot.roadmaps, "\n", fn roadmap ->
        workflows =
          Enum.map_join(roadmap.workflows, "\n", fn workflow ->
            tasks =
              case workflow.tasks do
                [] -> "- No tasks"
                rows -> Enum.map_join(rows, "\n", &"- [#{&1.state}] `#{&1.id}` — #{&1.title}")
              end

            "### #{workflow.name} (`#{workflow.id}`)\n\n#{tasks}\n"
          end)

        "## #{roadmap.name} (`#{roadmap.key}`)\n\n#{workflows}"
      end)

    "# #{snapshot.project.name} (`#{snapshot.project.key}`)\n\n" <>
      "Generated read-only from SpruceGoose/Ash authority. Do not edit this view as input.\n\n" <>
      sections
  end

  defp dot(snapshot) do
    nodes =
      for roadmap <- snapshot.roadmaps,
          workflow <- roadmap.workflows,
          task <- workflow.tasks do
        ~s(  "#{task.id}" [label="#{escape_dot(task.title)}\\n#{task.state}"];)
      end

    "digraph sprucegoose {\n  rankdir=LR;\n" <> Enum.join(nodes, "\n") <> "\n}\n"
  end

  defp escape_dot(value) do
    value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
  end
end
