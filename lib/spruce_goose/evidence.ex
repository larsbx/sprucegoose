defmodule SpruceGoose.Evidence do
  @moduledoc """
  Detection of missing and unverified evidence.

  Motivating failure (2026-08-24): an analysis was narrated as recorded but
  never written to the task. SpruceGoose had nothing to reject, because the
  failure was an *absent* write rather than a bad transition. Silence read as
  "nothing to record".

  Three detections make that silence visible:

  * `stale_tasks/1` — in-progress work whose newest genuine evidence predates
    a supplied threshold, including work carrying no evidence at all.
  * `unproven_tasks/0` — tasks whose Definition of Done demands verification
    but which carry no `finding` or `regression`.
  * `unverified_completions/0` and `refuted_completions/0` — completed tasks
    whose declared claims were never probed, or were probed and failed.

  Freshness is computed only from genuine references. Backfilled rows carry a
  `nil` `recorded_at` because their true time was never captured, and counting
  them would manufacture the very confidence this module exists to withhold.

  This module selects and records. It never executes a probe: keeping shell
  access out of the data layer is what preserves replay and projection
  determinism. An external runner performs probes and returns verdicts.
  """
  require Ash.Query

  alias SpruceGoose.Workflows.{CompletionClaim, ReferenceKind, Task, TaskReference}

  # Vocabulary that marks a Definition of Done as making a verification claim.
  # Deliberately narrow: matching loosely would flag most tasks and turn the
  # detection into noise.
  @verification_terms ~w(
    verif prove proven proof independent
    re-probe reprobe probed compared
  )

  @doc """
  In-progress tasks whose newest genuine evidence is older than the threshold.

  A task with no references at all is always stale: that is the case the
  motivating failure produced.
  """
  def stale_tasks(opts \\ []) do
    threshold = Keyword.get(opts, :threshold_seconds, 86_400)
    cutoff = DateTime.add(DateTime.utc_now(), -threshold, :second)

    in_progress_tasks()
    |> Enum.filter(fn task ->
      case newest_genuine_reference(task.id) do
        nil -> true
        %DateTime{} = recorded_at -> DateTime.compare(recorded_at, cutoff) == :lt
      end
    end)
  end

  @doc """
  Tasks whose Definition of Done requires verification but which carry no
  proof reference.

  An `sop` or `session` link is context, not proof; only `finding` and
  `regression` satisfy this.
  """
  def unproven_tasks do
    in_progress_tasks()
    |> Enum.filter(&requires_verification?/1)
    |> Enum.reject(&has_proof_reference?/1)
  end

  @doc "Completed tasks carrying at least one claim nobody has probed."
  def unverified_completions do
    completed_tasks_with_claims(:unverified)
  end

  @doc "Completed tasks whose probe actively contradicted the completion."
  def refuted_completions do
    completed_tasks_with_claims(:refuted)
  end

  @doc """
  Attach a checkable claim to a task.

  Declaring never executes the probe; it records what ought to be true and
  which declared target it should be checked against.
  """
  def declare_claim(%Task{} = task, attrs) do
    Ash.create(
      CompletionClaim,
      %{
        task_id: task.id,
        target_key: Map.fetch!(attrs, :target_key),
        probe: Map.fetch!(attrs, :probe),
        expectation: Map.fetch!(attrs, :expectation)
      },
      action: :declare,
      authorize?: false
    )
  end

  @doc "Record an external runner's verdict against a claim."
  def record_verdict(%CompletionClaim{} = claim, attrs) do
    claim
    |> Ash.Changeset.for_update(:record_verdict, %{
      outcome: Map.fetch!(attrs, :outcome),
      detail: Map.get(attrs, :detail)
    })
    |> Ash.update(authorize?: false)
  end

  @doc """
  Create a reference for evidence rescued from `Task.input`.

  Marked `backfilled` with no `recorded_at`, so migration never fabricates a
  recording time it does not know.
  """
  def backfill_reference(attrs) do
    Ash.create(
      TaskReference,
      %{
        task_id: Map.fetch!(attrs, :task_id),
        kind: Map.fetch!(attrs, :kind),
        value: Map.fetch!(attrs, :value)
      },
      action: :backfill,
      authorize?: false
    )
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp in_progress_tasks do
    Task
    |> Ash.Query.filter(state == :in_progress)
    |> Ash.read!(authorize?: false)
  end

  # Only genuine references count. Backfilled rows have a nil `recorded_at`
  # and are excluded in SQL rather than being coerced to some default time.
  defp newest_genuine_reference(task_uuid) do
    TaskReference
    |> Ash.Query.filter(task_id == ^task_uuid and backfilled == false and not is_nil(recorded_at))
    |> Ash.Query.sort(recorded_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> case do
      [%TaskReference{recorded_at: recorded_at}] -> recorded_at
      [] -> nil
    end
  end

  defp requires_verification?(%Task{definition_of_done: nil}), do: false

  defp requires_verification?(%Task{definition_of_done: dod}) do
    normalized = String.downcase(dod)
    Enum.any?(@verification_terms, &String.contains?(normalized, &1))
  end

  defp has_proof_reference?(%Task{id: task_uuid}) do
    proof = ReferenceKind.proof_kinds()

    TaskReference
    |> Ash.Query.filter(task_id == ^task_uuid and kind in ^proof)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> Enum.any?()
  end

  defp completed_tasks_with_claims(outcome) do
    task_ids =
      CompletionClaim
      |> Ash.Query.filter(outcome == ^outcome)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.task_id)
      |> Enum.uniq()

    case task_ids do
      [] ->
        []

      ids ->
        Task
        |> Ash.Query.filter(state == :completed and id in ^ids)
        |> Ash.read!(authorize?: false)
    end
  end
end
