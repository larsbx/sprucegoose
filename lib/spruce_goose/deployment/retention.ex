defmodule SpruceGoose.Deployment.Retention do
  @moduledoc """
  Disposable preview environments and retention policy.

  This module decides what is *eligible* for reclamation. It deletes nothing.
  It drops no database, removes no artifact, and issues no shell command.
  Reclamation is executed only through an approved, single-use
  `:execute_reclaim` operation, and that path re-judges the preview against its
  live cohort with `assert_reclaimable/4` immediately before acting.

  Note the direction of the safety bias. For deploy gates, failing closed means
  refusing to proceed. For a destructive operation, failing closed means
  refusing to *delete*: any missing, undated, malformed, or ambiguous input
  keeps the resource. Uncertainty must never be resolved in favour of deletion.
  """

  alias SpruceGoose.Deployment.Lifecycle, as: Contract

  @environment :preview
  @default_ttl_seconds 72 * 3_600
  @default_grace_seconds 24 * 3_600
  @min_retained_per_project 3

  @doc "The only environment this capability may ever reclaim."
  def environment, do: @environment

  @doc "Default time-to-live before a terminal preview becomes reclaimable."
  def default_ttl_seconds, do: @default_ttl_seconds

  @doc "Additional grace period applied after the TTL expires."
  def default_grace_seconds, do: @default_grace_seconds

  @doc "Newest previews per project that are always retained regardless of age."
  def min_retained_per_project, do: @min_retained_per_project

  @doc """
  Select previews eligible for reclamation.

  Returns `{:ok, %{eligible: [...], retained: [...]}}` where every retained
  entry carries the reason it was kept. Reclamation is a proposal for an
  operator or a later approved mutation path, never an action taken here.

  The whole selection is refused if the supplied recovery evidence does not
  show a verified restore, because reclaiming data that cannot be restored is
  not disposal, it is loss.
  """
  def select_reclaimable(previews, policy \\ %{}, now \\ DateTime.utc_now())

  def select_reclaimable(previews, %{} = policy, %DateTime{} = now) when is_list(previews) do
    with :ok <- check_recovery(policy) do
      ttl = positive_integer(policy, :ttl_seconds, @default_ttl_seconds)
      grace = positive_integer(policy, :grace_seconds, @default_grace_seconds)
      keep = positive_integer(policy, :min_retained_per_project, @min_retained_per_project)

      protected_ids = protected_newest_ids(previews, keep)

      {eligible, retained} =
        previews
        |> Enum.map(&classify(&1, now, ttl + grace, protected_ids))
        |> Enum.split_with(&match?({:eligible, _}, &1))

      {:ok,
       %{
         eligible: Enum.map(eligible, fn {:eligible, preview} -> preview end),
         retained: Enum.map(retained, fn {:retained, preview, reason} -> {preview, reason} end)
       }}
    end
  end

  def select_reclaimable(_, _, _), do: {:error, :invalid_retention_request}

  @doc """
  Confirm a single preview may be reclaimed, judged against its live cohort.

  Used as a final guard immediately before any future approved reclamation, so
  a stale batch decision cannot authorize deleting something that has since
  become protected.

  The cohort is required. Judging a preview in isolation would be unsound:
  per-project minimum retention is a property of the whole set, so a lone
  preview could otherwise appear reclaimable precisely when it is the last one
  standing.
  """
  def assert_reclaimable(preview, cohort, policy \\ %{}, now \\ DateTime.utc_now())

  def assert_reclaimable(%{} = preview, cohort, policy, now) when is_list(cohort) do
    id = Map.get(preview, :id)

    cond do
      not (is_binary(id) and id != "") ->
        {:error, :malformed_preview}

      not Enum.any?(cohort, &(is_map(&1) and Map.get(&1, :id) == id)) ->
        {:error, :not_in_cohort}

      true ->
        with {:ok, %{eligible: eligible, retained: retained}} <-
               select_reclaimable(cohort, policy, now) do
          if Enum.any?(eligible, &(Map.get(&1, :id) == id)) do
            :ok
          else
            case Enum.find(retained, fn {p, _} -> Map.get(p, :id) == id end) do
              {_, reason} -> {:error, reason}
              nil -> {:error, :not_reclaimable}
            end
          end
        end
    end
  end

  def assert_reclaimable(_, _, _, _), do: {:error, :invalid_retention_request}

  defp check_recovery(policy) do
    case Map.get(policy, :recovery) do
      %{restore_verified: true} -> :ok
      %{restore_verified: false} -> {:error, :recovery_restore_unverified}
      _ -> {:error, :recovery_unverified}
    end
  end

  defp classify(preview, now, max_age, protected_ids) when is_map(preview) do
    # Date integrity is judged before minimum-retention protection so an
    # operator is told the actionable truth ("this record is undated") rather
    # than an incidental one ("it happened to be among the newest"). Both
    # outcomes retain the preview, so reporting order changes no safety result.
    date_issue = date_issue(preview, now)

    cond do
      not valid_identity?(preview) ->
        {:retained, preview, :malformed_preview}

      Map.get(preview, :environment) != @environment ->
        {:retained, preview, :not_a_preview_environment}

      Map.get(preview, :pinned) == true ->
        {:retained, preview, :pinned}

      date_issue != nil ->
        {:retained, preview, date_issue}

      Map.get(preview, :id) in protected_ids ->
        {:retained, preview, :within_minimum_retained}

      referenced?(preview) ->
        {:retained, preview, :referenced_by_active_deployment}

      not terminal_state?(preview) ->
        {:retained, preview, :not_terminal}

      true ->
        classify_age(preview, now, max_age)
    end
  end

  defp classify(preview, _now, _max_age, _protected), do: {:retained, preview, :malformed_preview}

  defp date_issue(preview, now) when is_map(preview) do
    case Map.get(preview, :terminal_at) do
      %DateTime{} = terminal_at ->
        if DateTime.diff(now, terminal_at, :second) < 0, do: :terminal_in_future

      _ ->
        :undated
    end
  end

  defp date_issue(_, _), do: :malformed_preview

  defp classify_age(preview, now, max_age) do
    terminal_at = Map.fetch!(preview, :terminal_at)
    age = DateTime.diff(now, terminal_at, :second)

    if age <= max_age,
      do: {:retained, preview, :within_retention_window},
      else: {:eligible, preview}
  end

  # Guarded against non-map entries: a malformed element must be classified as
  # retained, never crash the selection or be skipped silently.
  defp valid_identity?(preview) when is_map(preview) do
    id = Map.get(preview, :id)
    project = Map.get(preview, :project)
    is_binary(id) and id != "" and is_binary(project) and project != ""
  end

  defp valid_identity?(_), do: false

  defp terminal_state?(preview) do
    Map.get(preview, :state) in Contract.terminal_states()
  end

  defp referenced?(preview) do
    case Map.get(preview, :active_references) do
      count when is_integer(count) -> count > 0
      nil -> false
      _ -> true
    end
  end

  # The newest previews per project are protected by identity, computed before
  # any age test, so a burst of old previews cannot strip a project bare.
  defp protected_newest_ids(previews, keep) do
    previews
    |> Enum.filter(&valid_identity?/1)
    |> Enum.group_by(&Map.get(&1, :project))
    |> Enum.flat_map(fn {_project, group} ->
      group
      |> Enum.sort_by(&sort_key/1, {:desc, DateTime})
      |> Enum.take(keep)
      |> Enum.map(&Map.get(&1, :id))
    end)
    |> MapSet.new()
  end

  # Undated previews sort oldest so they never consume a minimum-retention slot
  # that belongs to a real dated preview. They remain retained on their own
  # merits via the `:undated` classification, which is the more honest reason.
  defp sort_key(preview) do
    case Map.get(preview, :terminal_at) do
      %DateTime{} = at -> at
      _ -> ~U[0001-01-01 00:00:00Z]
    end
  end

  defp positive_integer(policy, key, default) do
    case Map.get(policy, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end
end
