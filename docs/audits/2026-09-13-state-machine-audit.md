# State machine audit — 2026-09-13

> **Remediated 2026-09-13.** F-01 was closed in the commit that added this
> document; F-02, F-03, F-04, F-05, F-08, F-12 and F-14 were closed in the
> commit that followed it. F-10 was decided (SOP hooks are mandatory on
> every entry into `in_progress`) and closed in a third commit. The info
> items (F-06, F-07, F-09, F-11, F-13) needed no action. The
> findings are left as written: an audit that gets edited to match the fix
> stops being evidence that the fix was needed. What each closure did, in one
> line each:
>
> - F-02: `TaskProjector.replay/3` enforces the task relation plus the
>   identity on every replayed task row; a forged edge refuses the rebuild.
> - F-03: `Deployment.Record` writes `state` only through a new
>   lifecycle-checked `:transition` action; `:project` no longer accepts it.
> - F-04: `workflow_tasks.state` carries a `CHECK` constraint generated from
>   the lifecycle module (`deployments.state` already had `deployment_shape`).
> - F-05: the permit's `state` and six dead outcome attributes are dropped.
> - F-08: the CLI precheck is deleted; the Task resource is the only guard.
> - F-12: `docs/lifecycles.md` is rendered from the modules and pinned by test.
> - F-14: a generation is born `active` and `:retire` refuses a second time.
> - F-10: `Task.validate_start/1` runs the SOP gate on every edge into
>   `in_progress`, so resuming from `waiting` re-verifies the acknowledgment.

**Verdict:** the two declared lifecycles (task, deployment) are sound as
relations: closed, irreflexive, every state reachable from the initial state,
every state able to reach a terminal state, and every sink terminal. Both are
now declarations on one shared contract, `SpruceGoose.Lifecycle`, whose static
invariants are checked at compile time and whose remaining properties the test
suite decides exhaustively. The defects are around the relations, not in them:
the task projector replays transitions without checking them while the
deployment projection does; the deployment record exposes a state-writing
action that bypasses its own lifecycle; the derivation permit declares a
four-state machine of which three states are unreachable.

Finding F-01 was remediated in the same change as this audit. The rest are
diagnosis: nothing else in the working tree was changed.

## Scope and evidence

Audited commit `2bd196d371cb901281e568f53367ce2336554c6a`, tree
`f48292870bfa2d9b6c360e8d9835d7aecd830793`, on a clean working tree, then the
change described under F-01 on top of it.

Evidence is direct source inspection plus a rebuilt toolchain and a full suite
run before and after the change:

| Component | Version | Provenance |
| --- | --- | --- |
| Erlang/OTP | 28.3.1 | `builds.hex.pm` prebuilt for ubuntu-24.04, SHA-256 verified, matching `.tool-versions` |
| Elixir | 1.19.5-otp-28 | `builds.hex.pm` prebuilt, SHA-256 verified, matching `.tool-versions` |
| PostgreSQL | 16.13 | Ubuntu 24.04 package; the schema migrated cleanly, so the PostgreSQL 18 requirement recorded on 2026-09-08 no longer holds |

| Run | Result |
| --- | --- |
| Baseline, before the change | 481 tests, 0 failures, 8 excluded (`:separate_sessions`) |
| After the change | 508 tests, 0 failures, 8 excluded |
| `mix compile --warnings-as-errors`, `mix format --check-formatted`, `git diff --check` | clean |

Every state machine is finite, so every property below was decided by
enumeration, not sampled. Notation: Σ is the state set, δ ⊆ Σ × Σ the
transition relation, δ⁺ its transitive closure, s₀ the initial state, T ⊆ Σ
the terminal set.

## Inventory

Everything in `lib/` that carries a state or status attribute, and whether a
relation is declared for it.

| # | Resource / module | Σ | s₀ | T | δ declared | Enforced by |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `Workflows.Task` via `Workflows.Lifecycle` | 10 | `inbox` | `completed`, `cancelled` | yes | Ash `:transition` and `:move` validations; four PostgreSQL triggers on specific edges |
| 2 | `Deployment.Record` via `Deployment.Lifecycle` | 10 | `queued` | `ready`, `failed`, `rolled_back`, `cancelled` | yes | `Deployment.transition/2` and `Deployment.Projection.step/3` |
| 3 | `Workflows.Revision` | `pending`, `applied`, `withdrawn` | `pending` | `applied`, `withdrawn` | inline (`require_pending/1`) | Ash `:approve`, `:withdraw` |
| 4 | `Workflows.InboxItem` | `pending`, `resolved`, `dropped` | `pending` | `resolved`, `dropped` | inline (`case state`) | Ash `:resolve` |
| 5 | `Derivations.Permit` | `admitted`, `claimed`, `succeeded`, `failed` | `admitted` | none reachable | no | nothing: no action writes `state` |
| 6 | `Outbox.Event.status` | `pending`, `dispatched`, `failed` | `pending` | `dispatched` | inline (conditional `UPDATE … WHERE status = 'pending'`) | compare-and-set queries; `CHECK` constraint |
| 7 | `Knowledge.Generation` | `active`, `retired` | caller-supplied | `retired` | inline | Ash `:retire` (unguarded) |
| 8 | `Runtime.ShadowSnapshot.status` | 7 normalized values | n/a | n/a | none, by design | append-only envelopes ordered by `revision` |
| 9 | `Deployment.Record.health_status` | `unknown`, `healthy`, `unhealthy` | `unknown` | n/a | none, by design | observation, not a lifecycle |
| 10 | `Derivations.OutcomeReceipt.outcome` | `succeeded`, `failed` | n/a | n/a | none | immutable value, not a lifecycle |

Rows 1 and 2 are the machines. Rows 3, 4 and 6 are two-step machines with
correct fail-closed guards. Rows 8 to 10 are values, not machines. Rows 5 and 7
are findings.

## The two declared machines

### Task lifecycle — `SpruceGoose.Workflows.Lifecycle`, version 1

| from | to |
| --- | --- |
| `inbox` | `proposed`, `cancelled` |
| `proposed` | `queued`, `cancelled` |
| `queued` | `ready`, `blocked`, `cancelled` |
| `ready` | `in_progress`, `blocked`, `cancelled` |
| `in_progress` | `waiting`, `blocked`, `completed`, `failed`, `cancelled` |
| `waiting` | `ready`, `in_progress`, `blocked`, `cancelled` |
| `blocked` | `ready`, `cancelled` |
| `failed` | `queued`, `cancelled` |
| `completed` | — |
| `cancelled` | — |

|Σ| = 10, |δ| = 23, s₀ = `inbox`, T = {`completed`, `cancelled`} = sinks.

Data-dependent guards on top of δ, all in `Workflows.Task`:

| Edge | Guard | Layer |
| --- | --- | --- |
| `ready → in_progress` | Systemwide SOP acknowledgment current (`SopGate.verify/1`) | Ash |
| `* → in_progress` | every predecessor `completed` | Ash and trigger `workflow_tasks_start_predecessor_guard` |
| `* → ready` | every `artifact_requirements` entry has a verified receipt | Ash and trigger `workflow_tasks_artifact_receipt_guard` |
| `* → completed` | every TODO completed; diagnosis tasks carry finding, regression and SOP references | Ash and trigger `workflow_tasks_completion_todo_guard` |
| `* → waiting`, `* → cancelled` | non-blank reason | Ash |
| any, when on a board | a column exists for the target state | Ash (`align_board_column/2`) and trigger `workflow_tasks_board_membership` |

### Deployment lifecycle — `SpruceGoose.Deployment.Lifecycle`, version 1

| from | to |
| --- | --- |
| `queued` | `building`, `cancelled` |
| `building` | `staged`, `failed`, `cancelled` |
| `staged` | `deploying`, `cancelled` |
| `deploying` | `verifying`, `failed`, `rolling_back` |
| `verifying` | `ready`, `failed`, `rolling_back` |
| `ready` | `rolling_back` |
| `failed` | `rolling_back` |
| `rolling_back` | `rolled_back`, `failed` |
| `rolled_back` | — |
| `cancelled` | — |

|Σ| = 10, |δ| = 17, s₀ = `queued`, T = {`ready`, `failed`, `rolled_back`,
`cancelled`} ⊋ sinks = {`rolled_back`, `cancelled`}. "Terminal" here means
*finished*, not *absorbing*: rollback is a new operation on a finished
deployment.

### Properties decided for both

| Property | Formal statement | Task | Deployment |
| --- | --- | --- | --- |
| Closure | ∀(a,b)∈δ. a∈Σ ∧ b∈Σ; s₀∈Σ; T⊆Σ | holds | holds |
| Irreflexive | ∀s. (s,s)∉δ | holds | holds |
| Sinks terminal | ∀s. δ(s)=∅ ⇒ s∈T | holds | holds |
| Reachability | δ⁺(s₀) ∪ {s₀} = Σ | holds | holds |
| Co-reachability | ∀s. (δ⁺(s) ∪ {s}) ∩ T ≠ ∅ | holds | holds |
| Absorbing terminals | ∀t∈T. δ(t)=∅ | holds | **does not hold** (`ready`, `failed`) — by design |
| Acyclic | δ⁺ irreflexive | no: `in_progress ⇄ waiting`, `failed → queued → …` | no: `failed ⇄ rolling_back` |

Closure and sinks-terminal are checked when each module compiles
(`SpruceGoose.Lifecycle.verify!/4`). The rest are decided in
`test/lifecycle_test.exs`, which enumerates Σ × Σ for both modules.

## Findings

Severity: **high** — a state can be reached or recorded that the relation
forbids; **medium** — the relation is enforced in one plane but not its
mirror; **low** — duplication or vestigial structure that will mislead a
change; **info** — a property worth knowing, no action.

### F-01 · medium · remediated · the two lifecycles were asymmetric

Before this change `Workflows.Lifecycle` was an undocumented map with
`allowed?/2` and `allowed_from/1`; `Deployment.Lifecycle` carried a version,
exported states, a terminal set, `transition/2` and `parse/1`. `TaskState`
restated the task state set by hand, so the enum and the relation could
drift without a compile error.

Remediation, in this commit:

- `SpruceGoose.Lifecycle` (`lib/spruce_goose/lifecycle.ex`) is a behaviour and
  `__using__` macro. A machine is one declaration: `version`, `initial`,
  ordered `transitions`, optional `terminal` (defaulting to the sinks). It
  generates `version/0`, `initial/0`, `states/0`, `transitions/0`,
  `terminal_states/0`, `terminal?/1`, `successors/1`, `transition/2`,
  `allowed?/2`, `allowed_from/1`, `parse/1`, `reachable/1`.
- `verify!/4` runs at compile time and refuses undeclared successors, an
  undeclared initial or terminal state, a duplicated state, and a sink that is
  not terminal.
- Both lifecycles are now declarations on it. The deployment relation, terminal
  set, `environments/0` and `requires_routing?/1` are byte-for-byte the same
  semantics; `states/0` now returns declaration order instead of `Map.keys/1`
  order, and no caller depended on the order.
- `TaskState` is `use Ash.Type.Enum, values: Workflows.Lifecycle.states()`.
  Σ is stated once.
- `test/lifecycle_test.exs` decides the property table above for both modules
  and pins both relations exactly, so a change to either is a visible diff in a
  test.

### F-02 · medium · open · the task projector trusts transitions the deployment projection checks

`Deployment.Projection.step/3` (`lib/spruce_goose/deployment/projection.ex:87`)
replays each `DeploymentTransitioned` event through `Lifecycle.parse/1` and
`Lifecycle.transition/2`, so certified history containing an illegal edge
fails to project.

`Kernel.TaskProjector.replay/3` (`lib/spruce_goose/kernel/task_projector.ex:93`)
replays `transition_task` and `move_task` results by overwriting the task row
with the event's `result`. It never consults `Workflows.Lifecycle`. A
`MutationAccepted` event whose result carries `state: completed` for a task the
projection holds in `inbox` is accepted and becomes the authoritative
projection.

Today every such event is produced by the Ash action that already validated the
edge, so the projection and the live table agree (`TaskProjector.status/0`
reports parity). The gap is in what the evidence plane can *detect*: the
deployment side would catch a forged or corrupted transition event; the task
side would not.

Proposed patch: in `replay/3`, for commands `transition_task` and `move_task`,
read the prior state from `acc["tasks"][id]["state"]` when present, and halt
with `{:error, :illegal_certified_transition}` unless
`Workflows.Lifecycle.transition(prior, next)` succeeds or `prior == next`
(`:move` admits the identity, see F-09). Add a regression that appends one
illegal edge to a certified stream and asserts the rebuild refuses. Baseline
rows and creation commands are unaffected.

### F-03 · medium · open · `Deployment.Record.:project` writes state without the lifecycle

`Deployment.Record`'s `:project` update action accepts `:state`
(`lib/spruce_goose/deployment/record.ex:99`) and is authorized for the
`operator` and `deployment_executor` roles. `Deployment.transition/2` is the
only intended writer and it checks `Lifecycle.transition/2` and appends a
ledger event first. Nothing prevents a caller holding either role from
`Ash.update(record, %{state: :ready}, action: :project)` directly: the Ash
`one_of` constraint checks membership in Σ, not membership in δ, and no
PostgreSQL trigger guards `deployment_records.state` (the only trigger in that
domain protects `deployment_operations` identity columns).

Contrast `workflow_tasks`, whose four triggers guard the edges with data
preconditions, and whose Ash `:transition` action accepts nothing but
`to_state` and `reason`.

Proposed fix, smallest first: remove `:state` from `:project`'s accept list and
give `Record` a `:transition` action that takes `to_state`, validates
`Lifecycle.transition(data.state, to_state)`, and is the only action
`Deployment.transition/2` calls. A trigger comparing `OLD.state` to `NEW.state`
against the same relation would close the raw-SQL path too, at the cost of
restating δ in SQL; whether that cost is worth paying is the same decision
F-04 poses for tasks.

### F-04 · low · open · `workflow_tasks.state` is unconstrained text

`workflow_tasks.state` is `text NOT NULL DEFAULT 'inbox'` with no `CHECK`.
`board_columns.task_state` has `board_columns_valid_task_state`, which spells
out Σ literally. So Σ is enforced at the database for columns and only by the
Ash enum for tasks; raw SQL can store any string in a task's `state`, and the
edge triggers (which match on `'in_progress'`, `'ready'`, `'completed'`) will
simply not fire for it.

Adding a `CHECK` means a migration on every change to Σ. That is the right
cost for a constitutive change and the columns table already pays it.

### F-05 · low · open · `Derivations.Permit` declares a machine it never runs

`Permit` declares `@states [:admitted, :claimed, :succeeded, :failed]`, a
`state` attribute defaulting to `:admitted`, and `claimed_at`, `completed_at`,
`executor_id`, `failure_reason` attributes. Its only action is `:admit`. No
code path writes `state`, `claimed_at`, `completed_at`, `executor_id` or
`failure_reason` on a permit: `Derivations.Executor.record_outcome/2` writes
those facts to an `OutcomeReceipt`, and the CLI prints `permit.claimed_at`,
which is therefore always `nil`.

Three of four states are unreachable. The machine is vestigial: the real
lifecycle of a derivation is "one permit, at most one receipt", which is a
relation between two immutable rows, not a state on one of them.

Either wire the transitions (`admitted → claimed` inside
`Executor.execute_locked/2`, `claimed → succeeded | failed` alongside the
receipt) so the permit row tells the truth, or delete `state` and the four
dead attributes and let the receipt be the outcome. The second is smaller and
matches how the code already behaves.

### F-06 · info · `failed` means opposite things in the two machines

Task `failed` is recoverable (`failed → queued`) and not terminal. Deployment
`failed` is terminal and leads only to `rolling_back`. Both are deliberate and
both are now visible in one place: `Workflows.Lifecycle.terminal?(:failed)` is
`false`, `Deployment.Lifecycle.terminal?(:failed)` is `true`. Anyone writing
code generic over lifecycles must use `terminal?/1`, never the state name.

### F-07 · info · the deployment relation has a `failed ⇄ rolling_back` cycle

`failed → rolling_back → failed` is legal, so a deployment can fail, roll back,
fail rolling back, and roll back again without bound. Each step is an
operator-initiated operation, so this is not a livelock. One consequence:
`terminal_at` is set on the first entry into T and never reset
(`Deployment.transition/2`), so a deployment that cycles through `failed`
twice reports the first failure's time. Retention judges only membership in T,
so retention is unaffected.

### F-08 · low · open · the CLI restates the start guard

`Cli.Executor.require_transition_preconditions/2`
(`lib/spruce_goose/cli/executor.ex:1549`) re-implements the `ready →
in_progress` guard (SOP gate plus predecessor completeness) that
`Task.validate_start/1` and `Task.validate_predecessors/1` already enforce, and
that `workflow_tasks_start_predecessor_guard` enforces again in PostgreSQL. The
database copy is defence in depth against non-Ash writers; the CLI copy exists
only to phrase the refusal before the Ash call and will drift first. Delete
it and map the Ash error to the message.

### F-09 · info · `:move` admits the identity, `:transition` does not

δ is irreflexive. `Task.:move` accepts `from == to` so a task can be re-ranked
within its column; `Task.:transition` refuses it. So `:move` enforces δ ∪ id
and `:transition` enforces δ. Correct, and worth stating because F-02's patch
has to honour it.

### F-10 · info · question · resuming from `waiting` skips the SOP gate

`validate_start/1` runs the SOP gate only on `ready → in_progress`. The edge
`waiting → in_progress` is legal and does not re-run it, so a task that was
paused while the Systemwide SOP changed resumes against a stale
acknowledgment. Completion is still gated elsewhere. Whether resumption should
re-verify is a policy decision under `docs/sop-versioning.md`, not a defect in
the relation; if the answer is yes, the fix is to drop the `data.state ==
:ready` condition in `validate_start/1`.

### F-11 · info · two-step machines are guarded inline, and that is fine

`Revision` (`pending → applied | withdrawn`) and `InboxItem` (`pending →
resolved | dropped`) guard their single non-terminal state with one `case` each.
Both are fail-closed and their terminal states are absorbing. Declaring them
on `SpruceGoose.Lifecycle` would add symmetry and nothing else. No action.

### F-12 · low · open · the deployment lifecycle diagram is incomplete and the task lifecycle is undocumented

`docs/deployment-domain.md` § Lifecycle draws 8 of the 17 edges; it omits
`building → failed`, `staged → cancelled`, `deploying → rolling_back`,
`verifying → rolling_back`, `ready → rolling_back` and `rolling_back →
failed`. No document outside code states the task relation at all. The tables
in this audit are exact; the module docs now carry the semantics. Point both
documents at the modules rather than maintaining a second drawing.

### F-13 · info · the outbox status machine is sound

`pending → dispatched` on success; `pending → pending` with backoff and
`attempts + 1` on failure below the cap; `pending → failed` at the cap;
`failed → pending` only through `Outbox.Operator` requeue. Every write is a
conditional `UPDATE … WHERE status = 'pending'` (or `'failed'` for requeue),
so a concurrent worker loses the race rather than double-dispatching, and the
`CHECK` constraint pins Σ. `dispatched` is absorbing. No action.

### F-14 · low · open · a knowledge generation can be born retired

`Knowledge.Generation.:create` accepts `:state`, so a caller can create a
generation already `retired`; `:retire` has no guard, so retiring twice is a
silent no-op. Neither is harmful today, but the first is a state machine whose
initial state is caller-chosen. Default `state` to `:active`, drop it from the
accept list, and let `:retire` refuse when already retired if a double retire
should be visible.

## Summary

| ID | Severity | Status | Where |
| --- | --- | --- | --- |
| F-01 | medium | remediated | `lib/spruce_goose/lifecycle.ex`, both `lifecycle.ex`, `task_state.ex`, `test/lifecycle_test.exs` |
| F-02 | medium | open | `kernel/task_projector.ex` |
| F-03 | medium | open | `deployment/record.ex`, `deployment.ex` |
| F-04 | low | open | migration on `workflow_tasks.state` |
| F-05 | low | open | `derivations/permit.ex`, `derivations/executor.ex`, `cli/executor.ex` |
| F-06 | info | — | both lifecycles |
| F-07 | info | — | `deployment/lifecycle.ex`, `deployment.ex` |
| F-08 | low | open | `cli/executor.ex` |
| F-09 | info | — | `workflows/task.ex` |
| F-10 | info | question | `workflows/task.ex`, `docs/sop-versioning.md` |
| F-11 | info | — | `workflows/revision.ex`, `workflows/inbox_item.ex` |
| F-12 | low | open | `docs/deployment-domain.md` |
| F-13 | info | — | `outbox/` |
| F-14 | low | open | `knowledge/generation.ex` |

Recommended order for the open items: F-02 and F-03 first, because they are
the two places where the mirror of an enforced relation is not enforced; then
F-05, which removes a machine that lies; then F-04, F-08, F-12, F-14.
