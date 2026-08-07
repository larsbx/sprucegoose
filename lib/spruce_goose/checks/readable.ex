defmodule SpruceGoose.Checks.Readable do
  @moduledoc """
  Reads, filtered to the projects the actor can see.

  A filter check rather than a refusal on purpose: a `project:openclaw-system`
  reader running `task list` should get that project's tasks, not an
  authorization error. Refusing would make every list command depend on the
  caller already knowing its own scope.

  A global grant returns everything. An actor with **no** grants is refused
  outright — Ash collapses a constant-false filter into `Ash.Error.Forbidden`
  rather than an empty page, and that is the better answer here: "you hold no
  grants" is actionable, where an empty list reads as "no such data exists".
  The distinction only arises at zero grants; a scoped reader still filters.
  """

  use Ash.Policy.FilterCheck

  require Ash.Expr

  alias SpruceGoose.Actors.{Actor, Scope}

  @impl true
  def describe(_opts), do: "record belongs to a project the actor may read"

  @impl true
  def filter(actor, %{resource: resource}, _opts) do
    with %Actor{} <- actor,
         true <- Actor.active?(actor) do
      scoped_filter(resource, Scope.readable_projects(actor))
    else
      _ -> expr(false)
    end
  end

  defp scoped_filter(_resource, :global), do: expr(true)
  defp scoped_filter(_resource, []), do: expr(false)

  defp scoped_filter(resource, keys) do
    case Scope.read_path(resource) do
      # The inbox holds pre-triage captures that belong to no project yet, so a
      # project-scoped grant cannot cover them. Only a global reader sees them.
      nil -> expr(false)
      path -> path_filter(path, keys)
    end
  end

  defp path_filter([field], keys), do: expr(^ref(field) in ^keys)

  defp path_filter(path, keys) do
    {field, relationships} = List.pop_at(path, -1)
    expr(^ref(relationships, field) in ^keys)
  end
end
