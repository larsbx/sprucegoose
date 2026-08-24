defmodule SpruceGoose.ReferenceKindCorpusTest do
  @moduledoc """
  Spec for admitting the reference kinds that actually exist.

  Motivating defect (2026-08-24): `ReferenceKind` was written from the seven
  kinds AGENTS.md documents, but `task link ID KIND VALUE` never validated
  `kind`, so the live corpus grew to seventeen. Of 1310 references, 208 would
  have failed the enum constraint during backfill — including 192 `evidence`
  rows. A migration that rejects a sixth of the authority's own evidence is
  not a migration.

  Two distinct questions are settled here, and they are deliberately separate:

  1. Which kinds may be *stored*. Backfill must not drop real history, so the
     enum admits every kind the corpus contains.
  2. Which kinds count as *proof* for `unproven_tasks/0`. Admitting a value
     is not the same as trusting it as verification.

  `evidence` is both: 28 tasks carry an `evidence` reference and no
  finding/regression, with values like `host-policy-commit:99c2b72`. It was
  used exactly as `finding` and `regression` were, before that vocabulary was
  documented. Excluding it from proof would report those 28 tasks as unproven
  while they carry real proof.

  The eight singleton kinds are admitted for storage only. They are one-off
  labels from individual sessions, not an established vocabulary, and nothing
  should treat them as verification.
  """
  use ExUnit.Case, async: true

  alias SpruceGoose.Workflows.ReferenceKind

  # Exactly the kinds observed in the live corpus survey, with their counts at
  # the time of the survey. Recorded here so a future reader can tell an
  # intentional vocabulary from an accident.
  @corpus_kinds ~w(
    repo regression evidence sop session finding flow repo_commit cron
    commit doc dogfood migration project roadmap task workflow
  )a

  describe "storage vocabulary" do
    test "admits every kind present in the live corpus" do
      allowed = MapSet.new(ReferenceKind.values())
      missing = @corpus_kinds |> MapSet.new() |> MapSet.difference(allowed)

      assert MapSet.size(missing) == 0,
             "these live kinds would fail backfill: #{inspect(MapSet.to_list(missing))}"
    end

    test "admits the documented seven" do
      allowed = MapSet.new(ReferenceKind.values())

      for kind <- ~w(finding regression sop flow cron session repo)a do
        assert MapSet.member?(allowed, kind)
      end
    end

    test "rejects a kind that is neither documented nor present in the corpus" do
      refute :not_a_real_kind in ReferenceKind.values()
    end
  end

  describe "proof semantics" do
    # Admitting a value for storage must not silently widen what counts as
    # verification: that would weaken the detection this whole task exists for.
    test "proof kinds are a strict subset of stored kinds" do
      allowed = MapSet.new(ReferenceKind.values())
      proof = MapSet.new(ReferenceKind.proof_kinds())

      assert MapSet.subset?(proof, allowed)
      assert MapSet.size(proof) < MapSet.size(allowed)
    end

    test "finding and regression remain proof" do
      assert :finding in ReferenceKind.proof_kinds()
      assert :regression in ReferenceKind.proof_kinds()
    end

    # 28 live tasks carry `evidence` and nothing else provable.
    test "evidence counts as proof because the corpus used it that way" do
      assert :evidence in ReferenceKind.proof_kinds()
    end

    # Context, not verification. An sop link says which rules applied; it does
    # not say anything was checked.
    test "context kinds are not proof" do
      proof = MapSet.new(ReferenceKind.proof_kinds())

      for kind <- ~w(sop session repo flow cron repo_commit)a do
        refute MapSet.member?(proof, kind), "#{kind} must not count as proof"
      end
    end

    # The ad-hoc singletons must never be treated as verification.
    test "one-off singleton kinds are not proof" do
      proof = MapSet.new(ReferenceKind.proof_kinds())

      for kind <- ~w(commit doc dogfood migration project roadmap task workflow)a do
        refute MapSet.member?(proof, kind), "#{kind} must not count as proof"
      end
    end
  end
end
