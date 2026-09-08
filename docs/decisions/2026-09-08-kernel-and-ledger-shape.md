# Decision records — 2026-09-08

Four decisions the [2026-09-08 audit](../audits/2026-09-08-project-audit.md)
forces and the [remediation plan](../audit-remediation-plan-2026-09-08.md)
records as T3/T4. One is decided and implemented. Three are **proposed and
awaiting owner sign-off**, and say so explicitly.

The split is not hedging. It follows the plan's own boundary: *no certified
event is deleted, rewritten, or re-rooted*. D-1 satisfies that — its
implementation is byte-identical to what it replaced, verified below. D-2, D-3
and D-4 all change what future immutable history means, and that is not a call
to make inside a remediation pass.

---

## D-1 · Canonical form — **decided, implemented**

**Question.** `Kernel.EventLedger` documented "ordered, immutable,
independently verifiable certified events". Identities are SHA-256 over
`:erlang.term_to_binary/2` output, which is Erlang External Term Format —
implementation-defined, and with `minor_version` unpinned, not even fixed
across runtime defaults.

**Decided.** Pin the encoding; withdraw the claim.

- `Kernel.Canonical` now passes `minor_version: 2` explicitly. Without it the
  variant was a property of the runtime rather than of the value.
- `Kernel.EventLedger`'s moduledoc no longer claims independent verifiability.
  `verify/2` re-derives an identity from stored bytes, which proves a ledger
  did not alter what it holds — a real and useful property, and a different one.

**Rejected: adopt a specified format now** (RFC 8785 JCS, or a length-prefixed
encoding defined in the module). This is the option that would *earn* the
withdrawn claim, and it should be taken eventually. It changes every existing
identity, so it re-roots history, so it is not a remediation change.

**Verification.** The pin had to be provably inert, or it would have silently
re-rooted production history:

```text
:erlang.term_to_binary(t, [:deterministic])
  == :erlang.term_to_binary(t, [:deterministic, minor_version: 2])
→ true for all 7 sample terms (objects, nested objects, bignums, lists,
  binaries, empty object) on OTP 28.3.1
```

**Cost of the residual.** A non-BEAM auditor still cannot recompute an event
identity. Anyone relying on independent verification should read the withdrawn
claim as the answer.

---

## D-2 · Certified stream shape — **proposed, awaiting sign-off**

Covers R-09 (partitioning) and R-10 (payload), which cannot be decided apart:
snapshots need less ordering than transitions do.

### What is true today

Every shadowed mutation writes to one stream, `"authority:sprucegoose"`.
`Postgres.EventLedger.append_transaction/1` takes `pg_advisory_xact_lock` on
that name and allocates position with `COALESCE(max(stream_position), 0) + 1`
over the whole stream. So all 25 shadowed verbs across every project serialize
behind one lock, and append cost grows with history.

`ShadowEvents.payload/2` puts the entire mutated record in `payload.result`;
`TaskProjector.replay/3` consumes it as `put_in(acc, ["tasks", id], task)`.

### Why they are one decision

The projector currently refuses non-contiguous history (`next != prior + 1`).
That is a stronger guarantee than a per-task projection needs, and it is
exactly what forces a single global stream and therefore the global lock.
Snapshot replay is last-write-wins, so it needs almost no ordering at all;
transition replay needs per-aggregate ordering and nothing more. Decide the
payload and the partitioning follows.

### Proposed

**Transitions, partitioned per project, with periodic snapshots.**

Rationale: the current arrangement reproduces, inside the mechanism built to
remediate F-02, the exact criticism F-02 made of the outbox — "events carry
aggregate snapshots rather than certified transitions". Three consequences are
already live: a dropped event is invisible whenever any later snapshot for the
same task survives; no event records what changed or why; and the production
parity proof is close to tautological, because replaying the last snapshot of
each row reproduces the rows.

**Rejected: keep snapshots.** Defensible, and cheaper — but then the ledger is
a state log, and `docs/current-state.md` should stop calling it a history. If
this option is taken, take the renaming with it.

**Rejected: per-workflow streams.** Finest concurrency, but cross-workflow task
moves then have no stream that orders them, and `move_task` is a supported verb.

**Rejected: one stream with a sequence.** Cheap positions, but `nextval` gaps on
rollback break the contiguity check the projector relies on, so it trades a
lock for a projector rewrite without changing the payload question.

### The criterion that settles it

**Does anything need to answer "why is this task in this state" from the ledger
alone?** If yes, snapshots can never answer it and the choice is forced. If the
honest answer is no, say so in `docs/current-state.md` and stop describing the
ledger as history.

### Why this cannot wait

Events written before this decision are written in whichever shape exists now,
and Phase 8 moves writers onto this path. A single global advisory lock is a
defensible shadow-mode simplification and is not a viable cutover write path.

---

## D-3 · Root semantics — **proposed, awaiting sign-off**

### What is true today

| Root | Source | Digest |
| --- | --- | --- |
| `ontology` | `lib/spruce_goose/kernel/constitution.ex` | `5a749225…` |
| `interpreter` | `lib/spruce_goose/kernel/constitution.ex` | `5a749225…` |
| `agent_charter` | `lib/spruce_goose/actors/registry.ex` | `11d5365d…` |
| `grant_epoch` | `lib/spruce_goose/actors/scope.ex` | `da82c82d…` |
| `policy` | `docs/authority-planes.md` | `30784cd5…` |
| `evidence_policy` | `docs/abstract-kernel-remediation-plan.md` | `8bc01ab6…` |
| `norm` | adopted Systemwide SOP digest | `560ad3ab…` |
| `schema` | migration-set digest | `71a2132e…` |

`ontology` and `interpreter` are byte-identical — the same file. No root is
ever resolved: `required_roots/1` checks `~r/\Asha256:[0-9a-f]{64}\z/`, shape
and not existence, and no code path calls `ArtifactStore.get/2` for a root. So
`verify` on a root is not merely unimplemented; it is not possible with what is
stored.

R-02 fixed the one root whose source was outside version control. The rest of
the finding stands.

### Proposed

**Rename them to provenance terms.**

Rationale: the names assert constitutional artifacts; the data are digests of
the running implementation and its planning documents. Of the two ways to
close that gap, this is the one that is true today. `evidence_policy` is the
remediation plan — a document describing work to be done, not an
evidence-admissibility policy — and no amount of resolution machinery makes it
one. Renaming keeps the real value (every event binds the exact implementation
and schema that produced it, which is genuine provenance) and stops the
vocabulary promising more.

**Rejected: make them constitutional.** Roots denote adopted artifacts,
retrievable and verifiable through `ArtifactStore`; `required_roots/1` resolves
and verifies them. This is the better end state and it is what the kernel
contract asks for. It is rejected *now* because it depends on D-4 and on Phase
0 landing (see R-12: the specification's bytes are not in the repository), and
because writing resolution machinery over roots that do not yet denote
constitutional artifacts would deepen the problem rather than fix it.

### Non-negotiable either way

`ontology == interpreter` must go. Two roots holding one digest carry one bit
between them and cannot record "ontology X interpreted under interpreter Y",
which is the distinction the root set exists to make.

### Boundary

Whichever option is taken, existing certified events keep the roots they were
written with. Re-rooting history is out of scope and would need its own
governed transaction.

---

## D-4 · Kernel disposition — **proposed, awaiting sign-off**

### What is true today

`Kernel.Constitution` has exactly one caller: `test/constitutional_path_test.exs`.
Nothing in the CLI, the ledger, the projector, the executor, or any Ash action
reaches it. `docs/current-state.md` said "the deployed kernel also provides one
deterministic, content-addressed path…"; it ships in the release and nothing
invokes it. (R-05 corrected that sentence.)

And every constitutional question it appears to answer is a field the caller
supplies:

```elixir
defp supported_claim?(%{claim_supported?: true}), do: :ok
defp accepted_evidence?(%{evidence_status: :accepted}), do: :ok
defp compatible_norm?(%{ontology_norm_compatible?: true}), do: :ok
defp sufficient_authority?(%{authority: :sufficient}), do: :ok
defp conflict_free?(%{conflicts: []}), do: :ok
```

`defined_predicate?/1` checks a caller-supplied predicate against a
caller-supplied list and never consults the ontology root; `bound_referent?/1`
is the same shape. The module aliases only `Canonical` and `ContentID`.
`authorize/2` is a total function of its arguments.

### Proposed

**Rename it to describe what it does, and remove the derivation claims.**

Rationale: what the module actually provides — "a caller asserted these
premises, and here is a tamper-evident, content-addressed record of that
assertion" — is real, and a correctly-done smaller thing. The name and the
surrounding documentation promise a derivation. The v0.2 audit's own warning
applies directly: do not relabel a partial mechanism as a kernel.

The negative tests (`:unsupported_claim`, `:contested_evidence`,
`:insufficient_authority`, …) stay, reclassified as what they are: field
validation. They pass by flipping the field that names the answer, which is a
useful thing to pin and not a demonstration that anything was derived.

**Rejected: make it decide.** `authorize/2` takes an `ArtifactStore` and a
`KernelContext`, resolves the ontology root, derives predicates and referents
from the resolved ontology, takes evidence status from a stored evidence
record and authority from `Actors.Scope`; then one real admission path is wired
through it. This is the right end state. It is rejected *now* because it
depends on D-3 choosing "constitutional", which depends on Phase 0 landing, and
because the honest prerequisite question has not been answered.

### The criterion that settles it

**Is there a specific decision the system must make that today's Ash policies
plus lifecycle validation cannot?** If yes, that decision is the vertical slice
and "make it decide" is justified. If the honest answer is "not yet", renaming
is not a retreat — it is the difference between an artifact that misleads a
reader and one that does a smaller job correctly.

---

## Status

| Decision | State | Blocks |
| --- | --- | --- |
| D-1 canonical form | decided, implemented, verified inert | — |
| D-2 stream shape | proposed | Phase 8 cutover |
| D-3 root semantics | proposed | D-4 |
| D-4 kernel disposition | proposed | conformance claims |

D-2 is the one with a deadline: every event written before it is settled is
written in the shape being decided.
