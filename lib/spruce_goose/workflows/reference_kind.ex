defmodule SpruceGoose.Workflows.ReferenceKind do
  @moduledoc """
  The kinds of evidence a task can carry.

  This enum was first written from the seven kinds AGENTS.md documents, but
  `task link ID KIND VALUE` never validated `kind`, so the live corpus grew to
  seventeen. A survey of 1310 references found 208 that the narrow enum would
  have rejected during backfill, including 192 `evidence` rows. A migration
  that discards a sixth of the authority's own evidence is not a migration, so
  the vocabulary admits what the corpus actually contains.

  Storage and proof are deliberately separate questions:

  * every value here may be *stored*, so history survives migration intact;
  * only `proof_kinds/0` counts as *verification* for `unproven_tasks/0`.

  Admitting a value is not the same as trusting it.
  """
  use Ash.Type.Enum,
    values: [
      # Documented vocabulary.
      :finding,
      :regression,
      :sop,
      :flow,
      :cron,
      :session,
      :repo,

      # Substantive kinds the corpus grew before the vocabulary was written.
      # `evidence` (192 rows) carried values like `host-policy-commit:99c2b72`;
      # `repo_commit` (8 rows) used the `owner@sha` form, a repo pin.
      :evidence,
      :repo_commit,

      # One-off labels, each appearing exactly once, kept so backfill preserves
      # history rather than dropping rows. These are not a vocabulary anyone
      # should extend; new work should use the documented kinds above.
      :commit,
      :doc,
      :dogfood,
      :migration,
      :project,
      :roadmap,
      :task,
      :workflow
    ]

  # `evidence` is included because the corpus used it exactly as `finding` and
  # `regression` were used, before that distinction existed: 28 tasks carry an
  # `evidence` reference and no finding/regression. Excluding it would report
  # those tasks as unproven while they hold real proof. It is a legacy proof
  # kind; new work should record `finding` or `regression`.
  @proof [:finding, :regression, :evidence]

  @doc """
  Kinds that constitute verification, as opposed to context.

  A `sop` link says which rules applied; a `session` or `repo` link says where
  work happened. Neither asserts that anything was checked.
  """
  def proof_kinds, do: @proof
end
