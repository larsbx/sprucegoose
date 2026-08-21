defmodule SpruceGoose.Legibility do
  @moduledoc "Read-only human and machine projections of SpruceGoose authority."

  alias SpruceGoose.Authz
  alias SpruceGoose.Workflows.Project

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
