defmodule SpruceGoose.Workflows.ReferenceKind do
  @moduledoc """
  Reference kinds: an open storage vocabulary with a closed proof set.

  This was twice modelled as an `Ash.Type.Enum` — first with the seven kinds
  AGENTS.md documents, then widened to seventeen. Both were measured against a
  local development database rather than the authority. The authority holds
  **105 distinct kinds** across 2831 references, 63 of them appearing exactly
  once, the longest 47 characters. `task link ID KIND VALUE` never validated
  `kind`, so the vocabulary is genuinely open-ended, not under-documented.

  Enumerating it would encode one-off session labels as constitutional
  vocabulary and break on the next novel kind. So storage accepts what the
  authority actually holds, and the closed set lives here instead.

  Only one question is load bearing: **does this reference assert that
  something was checked?** The detections ask that; they never ask whether a
  kind is recognised.

  `proof?/1` is deliberately exact-match. Because storage is open, novel kinds
  reach it routinely, and anything unrecognised must read as *not proof* —
  otherwise `unproven_tasks/0` would fall silent exactly when a task carried
  nothing but improvised labels.
  """

  # `evidence` is included because the corpus used it exactly as `finding` and
  # `regression` were used, before that distinction existed. Excluding it would
  # report tasks holding real proof as unproven. New work should record
  # `finding` or `regression`.
  @proof ~w(finding regression evidence)

  # The vocabulary AGENTS.md documents. Retained for guidance and tooling, not
  # as a storage constraint: an unlisted kind is stored, it is simply not
  # blessed.
  @documented ~w(finding regression sop flow cron session repo)

  @doc """
  Kinds that assert verification, as opposed to context.

  A `sop` link says which rules applied; a `session` or `repo` link says where
  work happened. Neither asserts that anything was checked.
  """
  def proof_kinds, do: @proof

  @doc """
  Whether a kind asserts verification.

  Exact match only. `"finding-summary"` and `"evidence-sha256"` are not proof:
  substring matching would let any improvised label containing a proof word
  silently satisfy the detection.
  """
  def proof?(kind) when is_binary(kind), do: kind in @proof
  def proof?(_), do: false

  @doc "The documented vocabulary, for guidance rather than enforcement."
  def documented_kinds, do: @documented
end
