defmodule SpruceGoose.EvidenceAbsenceDetectionTest do
  @moduledoc """
  Spec for making missing and unverified evidence detectable inside Ash.

  Motivating failure (2026-08-24): an analysis was narrated as recorded but
  never written to the task. SpruceGoose could not surface it because an
  *absent* write produces no bad transition to reject — silence is
  indistinguishable from a turn with nothing to record.

  References previously lived as anonymous maps inside `Task.input`, with no
  per-reference timestamp, so "newest evidence older than N" was unanswerable.
  These tests demand a real `TaskReference` resource with `recorded_at`.

  Each test names the DoD clause it enforces.
  """
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Actors.{Actor, Grant}
  alias SpruceGoose.Authz
  alias SpruceGoose.Evidence

  alias SpruceGoose.Workflows.{
    Definition,
    Project,
    Roadmap,
    Task,
    TaskReference,
    VerificationTarget,
    Workflow
  }

  describe "TaskReference resource" do
    # DoD: "A TaskReference resource carries kind, value, recorded_at, and
    # recording actor, is registered in the Workflows domain, relates to Task"
    test "carries kind, value, recorded_at and recording actor" do
      task = task_fixture()
      actor = actor_with_role("evidence-writer", :operator)

      assert {:ok, reference} =
               Authz.with_actor(actor, fn ->
                 Authz.create(
                   TaskReference,
                   %{
                     task_id: task.id,
                     kind: "finding",
                     value: "proved by independent read"
                   },
                   action: :record
                 )
               end)

      assert reference.kind == "finding"
      assert reference.value == "proved by independent read"
      assert %DateTime{} = reference.recorded_at
      assert reference.recorded_by == "evidence-writer"
      refute reference.backfilled
    end

    # DoD: "is registered in the Workflows domain"
    test "is registered in the Workflows domain" do
      assert TaskReference in Ash.Domain.Info.resources(SpruceGoose.Workflows)
    end

    # DoD: evidence is a durable record, not a mutable blob. A reference that
    # can be silently edited after the fact is not evidence.
    test "is immutable once recorded" do
      assert Ash.Resource.Info.action(TaskReference, :update) == nil
    end

    # DoD: "written through the actor-bound authorization surface"
    test "refuses an unauthorized actor" do
      task = task_fixture()
      reader = actor_with_role("evidence-reader", :reader)

      assert {:error, _} =
               Authz.with_actor(reader, fn ->
                 Authz.create(
                   TaskReference,
                   %{task_id: task.id, kind: "finding", value: "unauthorized"},
                   action: :record
                 )
               end)
    end
  end

  describe "backfill provenance" do
    # DoD: "migrated rows are explicitly marked backfilled with unknown
    # recording time" — no synthetic timestamps.
    test "backfilled references are marked and carry no recorded_at" do
      task = task_fixture()

      assert {:ok, reference} = backfill(task, "finding", "migrated from Task.input")

      assert reference.backfilled
      assert is_nil(reference.recorded_at)
    end

    # DoD: "backfilled rows never count as genuine freshness".
    # This is the anti-fabrication guard: a task whose only evidence is
    # backfilled must still be reported as stale.
    test "a task with only backfilled evidence is still stale" do
      task = task_fixture(state: :in_progress)
      {:ok, _} = backfill(task, "finding", "historical, time unknown")

      stale = Evidence.stale_tasks(threshold_seconds: 0)

      assert task.task_id in Enum.map(stale, & &1.task_id)
    end
  end

  describe "staleness detection" do
    # DoD: "staleness for in-progress tasks whose newest genuine reference
    # predates a supplied threshold"
    test "reports an in-progress task carrying no evidence at all" do
      task = task_fixture(state: :in_progress)

      stale = Evidence.stale_tasks(threshold_seconds: 3600)

      assert task.task_id in Enum.map(stale, & &1.task_id)
    end

    # The detection must key on evidence recency, not on `updated_at`, which
    # moves for unrelated field changes and would report a freshly-touched
    # task as freshly-evidenced.
    test "does not report a task whose evidence is newer than the threshold" do
      task = task_fixture(state: :in_progress)
      {:ok, _} = record(task, "finding", "just recorded")

      stale = Evidence.stale_tasks(threshold_seconds: 3600)

      refute task.task_id in Enum.map(stale, & &1.task_id)
    end

    test "reports a task whose newest evidence predates the threshold" do
      task = task_fixture(state: :in_progress)
      {:ok, _} = record_at(task, "finding", "old", seconds_ago: 7200)

      stale = Evidence.stale_tasks(threshold_seconds: 3600)

      assert task.task_id in Enum.map(stale, & &1.task_id)
    end

    # Only in-progress work is subject to the staleness rule; a completed or
    # inbox task carrying no evidence is not a live omission.
    test "ignores tasks that are not in progress" do
      task = task_fixture(state: :inbox)

      stale = Evidence.stale_tasks(threshold_seconds: 0)

      refute task.task_id in Enum.map(stale, & &1.task_id)
    end
  end

  describe "evidence precondition detection" do
    # DoD: "a precondition detection for tasks whose Definition of Done
    # requires verification but which carry no finding or regression reference"
    test "reports a verification-requiring task with no finding or regression" do
      task =
        task_fixture(
          state: :in_progress,
          definition_of_done:
            "Every claim is proven by an independent read against the authority."
        )

      unproven = Evidence.unproven_tasks()

      assert task.task_id in Enum.map(unproven, & &1.task_id)
    end

    test "does not report a task once a finding is recorded" do
      task =
        task_fixture(
          state: :in_progress,
          definition_of_done:
            "Every claim is proven by an independent read against the authority."
        )

      {:ok, _} = record(task, "finding", "independent read performed")

      unproven = Evidence.unproven_tasks()

      refute task.task_id in Enum.map(unproven, & &1.task_id)
    end

    # A DoD with no verification vocabulary is out of scope; flagging it would
    # make the detection noise rather than signal.
    test "ignores a task whose definition of done requires no verification" do
      task = task_fixture(state: :in_progress, definition_of_done: "Rename the column.")

      unproven = Evidence.unproven_tasks()

      refute task.task_id in Enum.map(unproven, & &1.task_id)
    end

    # An sop reference is not proof of verification; only finding/regression are.
    test "an sop reference alone does not satisfy the precondition" do
      task =
        task_fixture(
          state: :in_progress,
          definition_of_done: "Every claim is verified against live state."
        )

      {:ok, _} = record(task, "sop", "/path/to/sop")

      unproven = Evidence.unproven_tasks()

      assert task.task_id in Enum.map(unproven, & &1.task_id)
    end
  end

  describe "verification targets are data, not hardcoded hosts" do
    # DoD: "a typed target resource describes each destination and its access
    # method, and no host name, address, or path is embedded in check logic"
    test "a target is a typed record carrying its access method" do
      actor = actor_with_role("target-admin", :operator)

      assert {:ok, target} =
               Authz.with_actor(actor, fn ->
                 Authz.create(
                   VerificationTarget,
                   %{
                     key: "mama",
                     description: "Production authority host",
                     access_method: :ssh,
                     address: "mama"
                   },
                   action: :declare
                 )
               end)

      assert target.key == "mama"
      assert target.access_method == :ssh
    end

    # The portability requirement: the same task, re-pointed at a different
    # target, must be verifiable without touching check logic.
    test "a completion claim binds to a target by key, not by literal host" do
      task = task_fixture(state: :completed)
      {:ok, _} = declare_target("future-box", :ssh, "somewhere-else")

      {:ok, claim} =
        Evidence.declare_claim(task, %{
          target_key: "future-box",
          probe: "test -s /path/to/artifact",
          expectation: :exit_zero
        })

      assert claim.target_key == "future-box"
      refute String.contains?(claim.probe, "mama")
    end

    # Determinism guard: the data layer must not shell out. Probe execution
    # belongs to an external runner; Ash owns selection and verdict storage.
    test "declaring a claim does not execute the probe" do
      task = task_fixture(state: :completed)
      {:ok, _} = declare_target("unreachable", :ssh, "no-such-host.invalid")

      assert {:ok, _claim} =
               Evidence.declare_claim(task, %{
                 target_key: "unreachable",
                 probe: "false",
                 expectation: :exit_zero
               })
    end
  end

  describe "completion verification" do
    # DoD: "completion verification re-probing declared targets, demonstrated
    # against the known-false completions ... correctly reporting at least one
    # as unproven"
    test "a completed task with an unverified claim is reported unproven" do
      task = task_fixture(state: :completed)
      {:ok, _} = declare_target("mama", :ssh, "mama")

      {:ok, _claim} =
        Evidence.declare_claim(task, %{
          target_key: "mama",
          probe: "test -s ~/.local/share/openclaw-secrets/repo.key",
          expectation: :exit_zero
        })

      unverified = Evidence.unverified_completions()

      assert task.task_id in Enum.map(unverified, & &1.task_id)
    end

    # A verdict is evidence and must be stored as such.
    test "recording a verdict resolves the claim and is retained" do
      task = task_fixture(state: :completed)
      {:ok, _} = declare_target("mama", :ssh, "mama")

      {:ok, claim} =
        Evidence.declare_claim(task, %{
          target_key: "mama",
          probe: "test -s /some/path",
          expectation: :exit_zero
        })

      assert {:ok, verdict} =
               Evidence.record_verdict(claim, %{
                 outcome: :refuted,
                 detail: "file absent on target"
               })

      assert verdict.outcome == :refuted
      refute task.task_id in Enum.map(Evidence.unverified_completions(), & &1.task_id)
    end

    # The failure this whole task exists to prevent: a completion whose probe
    # refutes it must be surfaced, not silently accepted.
    test "a refuted verdict surfaces the completion as false" do
      task = task_fixture(state: :completed)
      {:ok, _} = declare_target("mama", :ssh, "mama")

      {:ok, claim} =
        Evidence.declare_claim(task, %{
          target_key: "mama",
          probe: "systemctl --user is-enabled woodpecker-server.service",
          expectation: :exit_nonzero
        })

      {:ok, _} = Evidence.record_verdict(claim, %{outcome: :refuted, detail: "still enabled"})

      refuted = Evidence.refuted_completions()

      assert task.task_id in Enum.map(refuted, & &1.task_id)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp task_fixture(opts \\ []) do
    state = Keyword.get(opts, :state, :inbox)
    dod = Keyword.get(opts, :definition_of_done, "Do the thing.")

    project = Ash.create!(Project, %{key: unique("proj"), name: "Proj"}, authorize?: false)

    roadmap =
      Ash.create!(
        Roadmap,
        %{project_id: project.id, key: unique("road"), name: "Road"},
        authorize?: false
      )

    {:ok, definition} = Definition.parse(%{tasks: [%{id: "fixture", kind: :openclaw}]})

    workflow =
      Ash.create!(
        Workflow,
        %{
          roadmap_id: roadmap.id,
          workflow_id: unique("wf"),
          name: "WF",
          definition: definition
        },
        authorize?: false
      )

    task =
      Ash.create!(
        Task,
        %{
          workflow_id: workflow.id,
          task_id: SpruceGoose.TaskId.generate(),
          title: "Fixture task",
          definition_of_done: dod,
          runner: :oban,
          priority: 1
        },
        authorize?: false
      )

    # `state` is not in the create accept list; it moves through `transition`.
    # Seed it directly so fixtures can start in any state without walking the
    # whole lifecycle, which is not what these tests are about.
    if state == :inbox, do: task, else: Ash.Seed.update!(task, %{state: state})
  end

  defp record(task, kind, value) do
    actor = actor_with_role(unique("writer"), :operator)

    Authz.with_actor(actor, fn ->
      Authz.create(TaskReference, %{task_id: task.id, kind: kind, value: value}, action: :record)
    end)
  end

  defp record_at(task, kind, value, seconds_ago: seconds) do
    with {:ok, reference} <- record(task, kind, value) do
      past = DateTime.add(DateTime.utc_now(), -seconds, :second)

      {:ok, Ash.Seed.update!(reference, %{recorded_at: past})}
    end
  end

  defp backfill(task, kind, value) do
    Evidence.backfill_reference(%{task_id: task.id, kind: kind, value: value})
  end

  defp declare_target(key, method, address) do
    actor = actor_with_role(unique("target-admin"), :operator)

    Authz.with_actor(actor, fn ->
      Authz.create(
        VerificationTarget,
        %{key: key, description: "fixture", access_method: method, address: address},
        action: :declare
      )
    end)
  end

  defp actor_with_role(name, role) do
    actor = Ash.create!(Actor, %{name: name, kind: :agent, created_by: "test"}, authorize?: false)

    Ash.create!(Grant, %{actor_id: actor.id, role: role, scope: "*", granted_by: "test"},
      authorize?: false
    )

    actor
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
