defmodule SpruceGoose.ReferenceKindCorpusTest do
  @moduledoc """
  Spec for reference kind as an open vocabulary with a closed proof set.

  This file previously encoded a superseded decision. On 2026-08-24 the kind
  was modelled as an `Ash.Type.Enum`, first with the seven kinds AGENTS.md
  documents, then widened to the seventeen found in a survey. Both attempts
  were measured against Papa's local development database, which is *not* the
  authority — a fact recorded on the owning task before the widening was
  committed, and then not applied to the widening itself.

  Surveying the live authority corrected the picture:

      corpus            local dev        authority
      tasks                   437              724
      references             1310             2831
      distinct kinds           17              105
      would fail backfill        0              149

  Of the 105 kinds, 63 appear exactly once, and the longest is 47 characters
  (`evidence-manifest-versioning-contract-sha256`). `task link ID KIND VALUE`
  never validated `kind`, so the vocabulary is genuinely open-ended rather
  than under-documented. Widening an enum a second time would encode one-off
  session labels as constitutional vocabulary and break on the next novel
  kind.

  So storage accepts what the authority actually holds, while `proof_kinds/0`
  stays closed. Those are different questions, and only the second one is load
  bearing: the detections ask "is this verified", never "is this kind known".

  The safety property that matters is at the bottom of this file — an
  unrecognised kind must never be mistaken for proof.
  """
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Actors.{Actor, Grant}
  alias SpruceGoose.Authz

  alias SpruceGoose.Workflows.{
    Definition,
    Project,
    ReferenceKind,
    Roadmap,
    Task,
    TaskReference,
    Workflow
  }

  describe "storage vocabulary is open" do
    # The authority holds 105 distinct kinds. Storage must not reject history.
    test "stores a kind that no enum anticipated" do
      task = task_fixture()

      assert {:ok, reference} = record(task, "mama-migration-inventory-sha256", "abc123")
      assert reference.kind == "mama-migration-inventory-sha256"
    end

    # Longest observed live kind is 47 characters.
    test "stores the longest kind observed in the authority" do
      task = task_fixture()
      kind = "evidence-manifest-versioning-contract-sha256"

      assert {:ok, reference} = record(task, kind, "digest")
      assert reference.kind == kind
    end

    test "stores the documented kinds unchanged" do
      task = task_fixture()

      for kind <- ~w(finding regression sop flow cron session repo) do
        assert {:ok, reference} = record(task, kind, "value for #{kind}")
        assert reference.kind == kind
      end
    end

    # Open does not mean unbounded: a blank kind carries no meaning and would
    # silently group unrelated evidence together.
    test "refuses a blank kind" do
      task = task_fixture()

      assert {:error, _} = record(task, "", "no kind")
    end
  end

  describe "proof set stays closed" do
    test "proof kinds are the three that assert verification" do
      assert Enum.sort(ReferenceKind.proof_kinds()) == ~w(evidence finding regression)
    end

    test "proof kinds are strings, matching how kind is now stored" do
      for kind <- ReferenceKind.proof_kinds() do
        assert is_binary(kind)
      end
    end

    test "recognises proof by value" do
      assert ReferenceKind.proof?("finding")
      assert ReferenceKind.proof?("regression")
      assert ReferenceKind.proof?("evidence")
    end

    # Context tells you where work happened or which rules applied. Neither
    # asserts that anything was checked.
    test "context kinds are not proof" do
      for kind <- ~w(sop session repo flow cron repo_commit doc project roadmap) do
        refute ReferenceKind.proof?(kind), "#{kind} must not count as proof"
      end
    end

    # The load-bearing safety property. Because storage is now open, an
    # unrecognised kind reaches this predicate routinely. If novelty defaulted
    # to proof, `unproven_tasks/0` would go quiet exactly when a task carried
    # nothing but improvised labels — the failure this whole task exists to
    # prevent.
    test "an unrecognised kind is never proof" do
      for kind <- ~w(
            mama-migration-inventory-sha256 split-from blocker erratum
            candidate-base-source-migrations totally-novel-kind
          ) do
        refute ReferenceKind.proof?(kind), "#{kind} must not count as proof"
      end
    end

    test "a kind that merely contains a proof word is not proof" do
      refute ReferenceKind.proof?("finding-summary")
      refute ReferenceKind.proof?("pre-regression")
      refute ReferenceKind.proof?("evidence-sha256")
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp record(task, kind, value) do
    actor = actor_with_role(unique("writer"), :operator)

    Authz.with_actor(actor, fn ->
      Authz.create(TaskReference, %{task_id: task.id, kind: kind, value: value}, action: :record)
    end)
  end

  defp task_fixture do
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

    Ash.create!(
      Task,
      %{
        workflow_id: workflow.id,
        task_id: SpruceGoose.TaskId.generate(),
        title: "Fixture task",
        definition_of_done: "Do the thing.",
        runner: :oban,
        priority: 1
      },
      authorize?: false
    )
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
