defmodule SpruceGoose.Blueprints.Applier do
  @moduledoc "Apply a validated repository blueprint to typed hierarchy resources."

  alias SpruceGoose.Authz
  alias SpruceGoose.Workflows.{Definition, Project, Roadmap, Workflow}

  @top_keys ~w(schema_version project roadmaps)
  @roadmap_keys ~w(key name workflows)
  @workflow_keys ~w(id name definition)

  def apply(project_id, bytes) when is_binary(bytes) do
    with {:ok, manifest} <- parse(bytes),
         {:ok, project} <- Authz.read_one(Project, id: project_id),
         :ok <- matching_project(manifest, project),
         {:ok, normalized} <- normalize(manifest) do
      # AUTHORIZATION: the enclosing BlueprintRevision :apply action requires an
      # approver; every nested hierarchy read/write still runs through Authz.
      case SpruceGoose.Repo.transaction(fn -> materialize(project, normalized) end) do
        {:ok, :ok} -> :ok
        {:error, error} -> {:error, error_message(error)}
      end
    end
  end

  defp parse(bytes) do
    case YamlElixir.read_from_string(bytes) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _} -> {:error, "blueprint must be a mapping"}
      {:error, _} -> {:error, "blueprint is not valid YAML"}
    end
  end

  defp matching_project(%{"schema_version" => 1, "project" => key}, %{key: key}), do: :ok

  defp matching_project(%{"schema_version" => version}, _),
    do: {:error, "unsupported blueprint schema version #{inspect(version)}"}

  defp matching_project(_, _), do: {:error, "blueprint project does not match the target project"}

  defp normalize(manifest) do
    with :ok <- exact_keys(manifest, @top_keys, "blueprint"),
         roadmaps when is_list(roadmaps) and roadmaps != [] <- manifest["roadmaps"],
         {:ok, roadmaps} <- map_ok(roadmaps, &normalize_roadmap/1),
         :ok <- unique(roadmaps, :key, "roadmap keys") do
      {:ok, roadmaps}
    else
      nil -> {:error, "blueprint roadmaps must be a non-empty list"}
      [] -> {:error, "blueprint roadmaps must be a non-empty list"}
      false -> {:error, "blueprint roadmaps must be a non-empty list"}
      {:error, _} = error -> error
      _ -> {:error, "blueprint roadmaps must be a non-empty list"}
    end
  end

  defp normalize_roadmap(value) when is_map(value) do
    with :ok <- exact_keys(value, @roadmap_keys, "roadmap"),
         {:ok, key} <- identifier(value["key"], "roadmap key"),
         {:ok, name} <- name(value["name"], "roadmap name"),
         workflows when is_list(workflows) and workflows != [] <- value["workflows"],
         {:ok, workflows} <- map_ok(workflows, &normalize_workflow/1),
         :ok <- unique(workflows, :workflow_id, "workflow ids") do
      {:ok, %{key: key, name: name, workflows: workflows}}
    else
      {:error, _} = error -> error
      _ -> {:error, "roadmap workflows must be a non-empty list"}
    end
  end

  defp normalize_roadmap(_), do: {:error, "roadmap must be a mapping"}

  defp normalize_workflow(value) when is_map(value) do
    with :ok <- exact_keys(value, @workflow_keys, "workflow"),
         {:ok, id} <- identifier(value["id"], "workflow id"),
         {:ok, name} <- name(value["name"], "workflow name"),
         {:ok, definition} <- Definition.parse(value["definition"]) do
      {:ok, %{workflow_id: id, name: name, definition: definition}}
    else
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp normalize_workflow(_), do: {:error, "workflow must be a mapping"}

  defp materialize(project, roadmaps) do
    Enum.reduce_while(roadmaps, :ok, fn spec, :ok ->
      with {:ok, roadmap} <- upsert_roadmap(project, spec),
           :ok <- materialize_workflows(roadmap, spec.workflows) do
        {:cont, :ok}
      else
        {:error, error} -> SpruceGoose.Repo.rollback(error)
      end
    end)
  end

  defp upsert_roadmap(project, spec) do
    case Authz.read_one(Roadmap, project_id: project.id, key: spec.key) do
      {:ok, roadmap} ->
        Authz.update(roadmap, %{name: spec.name}, action: :revise)

      {:error, "not found"} ->
        Authz.create(Roadmap, %{project_id: project.id, key: spec.key, name: spec.name},
          action: :apply_blueprint
        )

      error ->
        error
    end
  end

  defp materialize_workflows(roadmap, workflows) do
    Enum.reduce_while(workflows, :ok, fn spec, :ok ->
      result =
        case Authz.read_one(Workflow, roadmap_id: roadmap.id, workflow_id: spec.workflow_id) do
          {:ok, workflow} ->
            Authz.update(workflow, %{name: spec.name, definition: spec.definition},
              action: :revise
            )

          {:error, "not found"} ->
            Authz.create(Workflow, Map.put(spec, :roadmap_id, roadmap.id),
              action: :apply_blueprint
            )

          error ->
            error
        end

      case result do
        {:ok, _} -> {:cont, :ok}
        {:error, error} -> SpruceGoose.Repo.rollback(error)
      end
    end)
  end

  defp exact_keys(value, keys, label) do
    if Enum.sort(Map.keys(value)) == Enum.sort(keys),
      do: :ok,
      else: {:error, "#{label} has unknown or missing keys"}
  end

  defp identifier(value, label) when is_binary(value) do
    if Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,127}\z/, value),
      do: {:ok, value},
      else: {:error, "#{label} is invalid"}
  end

  defp identifier(_, label), do: {:error, "#{label} is invalid"}
  defp name(value, _label) when is_binary(value) and byte_size(value) in 1..200, do: {:ok, value}
  defp name(_, label), do: {:error, "#{label} is invalid"}

  defp map_ok(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp unique(values, key, label) do
    ids = Enum.map(values, &Map.fetch!(&1, key))

    if length(ids) == MapSet.size(MapSet.new(ids)),
      do: :ok,
      else: {:error, "#{label} must be unique"}
  end

  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: Exception.message(error)
end
