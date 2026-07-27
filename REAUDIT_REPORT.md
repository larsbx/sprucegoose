# Orchestrator Codebase Re-Audit Report

**Status:** Historical — superseded by `HANDOFF.md` and the completed authority cutover
**Audit date:** 2026-07-27  
**Scope:** Current staged Orchestrator application, operator CLI, Tuxedo ledger migration, lifecycle enforcement, PostgreSQL invariants, migrations, configuration, and tests  
**Primary concern:** Readiness for Ash CLI authority cutover and retirement of Tuxedo/taskctl

## Executive Summary

The original audit findings have been substantially remediated. Source files are now tracked, optimistic locking is used by normal Ash updates, dependency graph integrity is enforced in PostgreSQL, migrations support populated databases, production configuration is environment-driven, and database integration coverage has improved.

The current implementation nevertheless remains unsafe for authority cutover. This re-audit found one critical, four high-severity, and three medium-severity defects in the new ledger and operator lifecycle paths.

The most serious issue is that the migration-only ledger import remains available after cutover and can overwrite authoritative Ash state, reset lifecycle progress, erase native metadata, and bypass optimistic locking. The replacement CLI also compresses several governed lifecycle states into one `task start` operation and does not preserve the diagnosis evidence requirements enforced by taskctl.

All current automated checks pass. These findings concern semantic, transactional, and operational guarantees that the existing suite does not adequately test.

## Severity Summary

| Severity | Count |
|---|---:|
| Critical | 1 |
| High | 4 |
| Medium | 3 |
| Low | 0 |

## Findings

### REA-001: Post-cutover ledger import can overwrite authoritative Ash state

**Severity:** Critical  
**Category:** Authority integrity / destructive regression  
**Locations:**

- `lib/orchestrator/ledger.ex:331`
- `lib/orchestrator/ledger.ex:335`
- `lib/orchestrator/cli/command.ex:35`
- `README.md:57`

When an imported task already exists, `refresh_imported_task/1` directly replaces:

- Workflow membership
- Task type
- Title
- Definition of Done
- Lifecycle state
- The complete `input` map

The refresh is permitted whenever the existing record contains `legacy_source = "tuxedo"`. This marker remains on imported tasks after authority transfer.

The `ledger import` command is still exposed by the production CLI and documented as an operator command. After cutover, invoking it against the retired or frozen ledger can therefore reset authoritative state to historical values and erase Ash-native metadata added since import, including references, wait reasons, and cancellation reasons.

**Impact**

- Completed or active tasks can be moved back to historical ledger states.
- Native evidence and operational metadata can be erased.
- A retired migration source remains capable of changing authority state.
- The intended one-way authority transfer is reversible by an ordinary CLI command.

**Recommendation**

- Make ledger import unavailable after a durable cutover flag is set.
- Prefer removing import from the production escript after migration.
- If retention is necessary for disaster recovery, require an explicit offline recovery mode and a separate database.
- Never replace the entire `input` map; isolate immutable import provenance from native task metadata.
- Add a test proving that post-cutover import is rejected without changing any record.

**Cutover status:** Blocking.

---

### REA-002: Ledger refresh bypasses optimistic locking

**Severity:** High  
**Category:** Concurrency / data integrity  
**Location:** `lib/orchestrator/ledger.ex:335`

The refresh path updates `workflow_tasks` through direct SQL without checking or incrementing `lock_version`.

Normal task revisions and transitions use Ash optimistic locking, but a ledger refresh can change the same row while leaving its version unchanged. Any process holding a record loaded before the refresh still appears current and can subsequently write over the imported values.

**Impact**

- Stale writes may succeed after ledger refresh.
- The lock version no longer accurately represents the record history.
- Concurrency guarantees differ depending on which write path was used.

**Recommendation**

- Include the observed lock version in the update predicate.
- Increment `lock_version` atomically with every refresh.
- Prefer executing refreshes through an Ash action that uses the same optimistic-lock policy.
- Add a regression test where a record loaded before import is rejected as stale afterward.

---

### REA-003: `task start` bypasses governed lifecycle gates

**Severity:** High  
**Category:** Workflow authority / state machine  
**Locations:**

- `lib/orchestrator/cli/executor.ex:161`
- `lib/orchestrator/cli/executor.ex:178`
- `lib/orchestrator/workflows/lifecycle.ex:4`

New tasks begin in `inbox`. The CLI does not expose explicit proposal, queueing, or readiness commands. Instead, `task start` searches the transition graph and executes every state on a shortest path to `in_progress`.

A single command can therefore perform:

```text
inbox → proposed → queued → ready → in_progress
```

No proposal approval, admission check, scheduling decision, or readiness-specific precondition is evaluated at the intermediate states.

**Impact**

- The documented lifecycle exists structurally but not operationally.
- Operators can bypass governance stages unintentionally.
- Audit history shows transitions that were never individually authorized.
- Future validations on intermediate states may cause partial transitions.

**Recommendation**

- Expose explicit commands or actions for proposal, queueing, and readiness.
- Define and enforce preconditions for each governed transition.
- Restrict `task start` to tasks already in `ready`, or document and formally authorize a narrower state set.
- Test every allowed CLI transition from every lifecycle state.

---

### REA-004: Multi-step lifecycle operations are not transactional

**Severity:** High  
**Category:** Transactional integrity  
**Locations:**

- `lib/orchestrator/cli/executor.ex:41`
- `lib/orchestrator/cli/executor.ex:163`
- `lib/orchestrator/cli/executor.ex:197`

The CLI performs each intermediate lifecycle transition as a separate database update. Wait and cancellation reasons are then recorded through an additional, separate `revise` action.

If an intermediate transition fails, earlier transitions remain committed. If reason recording fails, the task state remains changed without the associated explanation.

**Impact**

- Failed commands can still modify task state.
- Tasks may stop in an unexpected intermediate state.
- Waiting or cancellation records can lack required reasons.
- Retrying the command may take a different path from the original attempt.

**Recommendation**

- Wrap the complete operator command in a database transaction.
- Prefer one domain action per operator intent.
- Store the target state and its reason atomically.
- Roll back all intermediate changes when any validation or persistence step fails.
- Add fault-injection tests proving that failed commands leave the original record unchanged.

---

### REA-005: Diagnosis completion evidence is not enforced

**Severity:** High  
**Category:** Completion governance / regression  
**Locations:**

- `lib/orchestrator/cli/executor.ex:41`
- `lib/orchestrator/cli/executor.ex:141`
- `lib/orchestrator/workflows/task.ex:85`

The retiring taskctl interface required diagnosis tasks to carry `finding`, `regression`, and `sop` references before completion.

The Ash CLI checks only that a task is currently in progress or waiting before moving it to `completed`. It does not inspect:

- `task_type`
- Evidence references
- Required TODO completion
- Definition-of-Done evidence

**Impact**

- Cutover weakens the existing diagnosis completion contract.
- Diagnosis tasks can be completed without durable findings or regression proof.
- A green lifecycle state may not represent satisfied governance requirements.

**Recommendation**

- Add a completion validation specific to `task_type = diagnosis`.
- Require the governed evidence kinds in structured task data.
- Validate required TODOs and Definition-of-Done evidence where applicable.
- Enforce the invariant in the Ash action or database-facing domain layer, not only the CLI.
- Add negative and positive integration tests.

---

### REA-006: Ledger parsing fails open on unknown status and type values

**Severity:** Medium  
**Category:** Import validation  
**Locations:**

- `lib/orchestrator/ledger.ex:59`
- `lib/orchestrator/ledger.ex:60`

Every type other than exactly `diagnosis` is silently converted to `task`. Unknown status values are silently converted to `queued`.

Malformed values, spelling mistakes, or future ledger schema additions can therefore change meaning without causing import to fail.

**Impact**

- Incorrect source data can be imported as valid authority state.
- Active or blocked tasks may be silently reclassified as queued.
- Unsupported task types lose their source meaning.
- Parity can still pass because it compares against the already-normalized interpretation.

**Recommendation**

- Validate status and task type against explicit allowlists.
- Reject unknown values with the source line number.
- Require and validate the source schema where present.
- Add tests for unknown, missing, and future values.

---

### REA-007: Ledger import cannot reconcile removed dependency edges

**Severity:** Medium  
**Category:** Migration drift / graph integrity  
**Locations:**

- `lib/orchestrator/ledger.ex:212`
- `lib/orchestrator/ledger.ex:259`

Import inserts dependency edges and ignores duplicates. It never removes an imported dependency that has disappeared from the source ledger.

Parity detects the obsolete edge and causes the transaction to roll back. This fails closed, but it also leaves no supported way to reconcile legitimate source drift.

**Impact**

- Re-import becomes permanently blocked after dependency removal.
- Operators may resort to manual SQL to restore parity.
- The documented idempotent refresh behavior does not cover dependency deletions.

**Recommendation**

- Track dependency provenance explicitly.
- Within the import transaction, calculate the expected imported edge set.
- Delete only obsolete edges owned by the Tuxedo import.
- Preserve native Ash dependency edges.
- Add tests for added, unchanged, and removed imported dependencies.

---

### REA-008: Links and lifecycle reasons cannot be inspected through the CLI

**Severity:** Medium  
**Category:** Operability / auditability  
**Locations:**

- `lib/orchestrator/cli/executor.ex:51`
- `lib/orchestrator/cli/executor.ex:197`
- `lib/orchestrator/cli/executor.ex:222`

`task link`, `task wait`, and `task cancel` store references or reasons in the task `input` map. The JSON returned by `task show` and `task list` excludes this map and does not expose structured references or reasons.

**Impact**

- Operators cannot verify linked evidence using the replacement CLI.
- Waiting and cancellation explanations are hidden.
- Diagnosis completion validation cannot be audited through the normal interface.
- The replacement interface has less observability than the authority it intends to replace.

**Recommendation**

- Return structured references, wait reasons, cancellation reasons, and import provenance from `task show`.
- Consider a concise representation for `task list`.
- Validate the JSON contract with CLI integration tests.

## Positive Observations

- The source-control ignore defect is corrected and application files are staged.
- Erlang/OTP and Elixir versions are pinned through `.tool-versions`.
- Normal Ash task and workflow updates use optimistic locking.
- PostgreSQL rejects cross-workflow dependency edges and persisted cycles.
- An advisory transaction lock protects concurrent dependency insertion.
- The hierarchy migration backfills existing workflows before adding non-null constraints.
- Production database configuration is supplied at runtime.
- The test environment uses the Ecto SQL sandbox.
- Ledger import is wrapped in a database transaction.
- Ledger parity includes task identity, hierarchy membership, title, Definition of Done, type, state, source representation, and dependency edges.
- Import refuses to overwrite tasks that are not marked as Tuxedo imports.
- Inbox captures remain separate from executable task authority.

## Verification Performed

The repository graph was refreshed before source exploration.

The following checks passed under Erlang/OTP 28.3.1 and Elixir 1.19.5-otp-28:

- Full ExUnit suite: **28 tests, 0 failures**
- Compilation with warnings treated as errors
- Formatting verification
- Ash/PostgreSQL migration drift check
- Escript build
- Staged Git diff whitespace validation

## Test Coverage Gaps

The current suite does not establish:

- Rejection of ledger import after cutover
- Preservation of native metadata during re-import
- Optimistic-lock invalidation after direct ledger refresh
- Atomic rollback of multi-step CLI transitions
- Explicit authorization of intermediate lifecycle states
- Diagnosis completion evidence requirements
- Rejection of unknown ledger statuses and task types
- Reconciliation of removed imported dependencies
- Visibility of links and reasons through `task show`

## Recommended Remediation Order

1. Disable or remove ledger import at the authority cutover boundary.
2. Eliminate direct, versionless task refreshes.
3. Replace automatic lifecycle graph traversal with explicit governed actions.
4. Make each operator lifecycle command transactional.
5. Restore diagnosis completion evidence enforcement.
6. Reject unknown ledger values.
7. Reconcile imported dependency deletions without touching native edges.
8. Expose evidence and reasons through the operator CLI.
9. Repeat import parity, rollback proof, and cutover rehearsal.

## Cutover Recommendation

**Do not retire Tuxedo/taskctl yet.**

The implementation now covers the major operator command categories, but it does not yet preserve the authority, lifecycle, evidence, concurrency, and observability guarantees required for a safe one-way cutover.

## Remediation Status — 2026-07-27

REA-001 through REA-008 are resolved in the working tree:

- A durable database authority flag rejects ledger import after cutover.
- Imported-task refresh preserves native metadata and increments `lock_version`.
- Lifecycle gates are explicit; `start` accepts only `ready`.
- State and wait/cancel reasons are written by one Ash update.
- Diagnosis completion requires finding, regression, and SOP references plus
  completed subordinate TODOs.
- Unknown ledger task types, statuses, and schemas fail closed.
- Imported dependency edges carry provenance and are reconciled without
  deleting native edges.
- Task JSON exposes references, reasons, and import provenance.

The focused adversarial database suite and full suite cover these guarantees.
Authority remains `tuxedo`; this remediation does not authorize cutover.
