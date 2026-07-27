# Orchestrator Post-Cutover Audit Report

Status: Validated — findings independently checked under
`tsk-20260727T154918Z-fdf80cd0`

Date: 2026-07-27 UTC  
Audited revision: `3001f69` (`Add unified Kanban task metadata`)  
Authority state: `ash`  
Cutover timestamp: `2026-07-27 12:00:27.831082 UTC`

## Executive summary

Orchestrator has a strong core: the Ash/PostgreSQL task model is compact,
dependency integrity is enforced in the database, task and board mutations use
optimistic locking, legacy ledger import fails closed after cutover, and the
full automated gate passes.

The post-cutover system is not yet fully hardened. This audit identified one
critical, two high, five medium, and one low-severity concern. The most serious
issue is that the supposedly one-way authority transfer is not irreversible at
the database layer. A database update can change the authority row back to
`tuxedo`, immediately re-enabling legacy ledger imports.

The new Kanban model also has incomplete relational invariants. A task can be
assigned to a board owned by a different workflow, and task lifecycle state can
diverge from the state represented by its board column. Completion governance
can likewise be invalidated by adding an incomplete TODO after a task has
already completed.

Recommended disposition: retain Ash as the live authority, keep ledger imports
disabled, and remediate the critical and high findings before treating the
post-cutover system as fully hardened.

## Scope

The audit covered:

- durable authority state and legacy-import gating
- task lifecycle and completion governance
- task, TODO, and evidence mutation paths
- project, roadmap, workflow, board, and column membership
- Kanban metadata and saved-filter validation
- optimistic-locking and concurrency behavior
- PostgreSQL constraints, triggers, migrations, and rollback structure
- canonical CLI capability and documentation accuracy
- automated tests and build-quality gates

The audit was read-only. No application or documentation files were changed
while the findings were developed.

## Method

The review followed the repository graph-first policy:

1. Queried the code graph for post-cutover correctness, authority, lifecycle,
   concurrency, migration, Kanban, and test risks.
2. Verified graph-selected resources and migrations directly in source.
3. Reviewed the recent commit sequence and current repository inventory.
4. Compared Ash validations with PostgreSQL constraints and triggers.
5. Examined canonical CLI admission and mutation paths.
6. Ran the complete quality gate and inspected live migration and authority
   state.

## Severity summary

| Severity | Count | Summary |
| --- | ---: | --- |
| Critical | 1 | Ash authority can be reversed, re-enabling legacy imports |
| High | 2 | Completion can be invalidated; board workflow membership is not enforced |
| Medium | 5 | State divergence, missing CLI operations, TODO races, optional cancellation reason, stale documentation |
| Low | 1 | Kanban/filter validation is too shallow |

## Findings

### PC-01 — Critical: authority transfer is reversible

The authority table accepts both `tuxedo` and `ash`, but no database invariant
prevents an `ash → tuxedo` transition. The row can also be changed without
preserving the existing cutover timestamp.

`Orchestrator.Authority.require_tuxedo/0` checks only the current `mode`.
Consequently, changing the row back to `tuxedo` immediately re-enables
`Ledger.import/1`. That import can refresh every record carrying Tuxedo
provenance from the preserved legacy ledger.

Evidence:

- `priv/repo/migrations/20260727104241_harden_authority_and_dependency_import.exs:25`
- `lib/orchestrator/authority.ex:6`
- `lib/orchestrator/authority.ex:13`
- `lib/orchestrator/ledger.ex:73`
- `lib/orchestrator/ledger.ex:360`

Impact:

- The documented one-way cutover is not actually one-way.
- An operator error, ad hoc database command, or compromised application
  credential could reactivate a retired authority source.
- A subsequent import could overwrite authoritative fields on imported tasks
  with stale legacy values.

Remediation:

1. Add a PostgreSQL trigger that permits only:

   ```text
   tuxedo, cutover_at NULL → ash, cutover_at NOT NULL
   ```

2. Reject all changes after the row reaches `ash`.
3. Prevent clearing or changing `cutover_at`.
4. Move any emergency reversal procedure behind a distinct, normally
   unavailable database role.
5. Add direct-SQL regression tests proving reversal and timestamp mutation are
   rejected.

Acceptance criteria:

- Raw SQL cannot change `ash` back to `tuxedo`.
- Raw SQL cannot clear or alter a completed cutover timestamp.
- Ledger import remains disabled after every attempted reversal.

### PC-02 — High: completed-task TODO invariants can be invalidated

Task completion checks that all TODOs visible at that moment are complete.
However, the canonical CLI and TODO resource allow a new incomplete TODO to be
created for a task in any state, including `completed`.

The result can be a completed task that no longer satisfies its own completion
requirements.

Evidence:

- `lib/orchestrator/workflows/task.ex:205`
- `lib/orchestrator/cli/executor.ex:82`
- `lib/orchestrator/cli/executor.ex:160`
- `lib/orchestrator/workflows/todo.ex:36`

Impact:

- Definition-of-Done evidence becomes mutable after completion.
- Completed task state no longer proves checklist completion.
- Reporting and downstream dependency admission can rely on an invalid state.

Remediation:

1. Reject TODO creation for `completed` and `cancelled` tasks.
2. Serialize TODO admission and completion against the owning task.
3. Prefer one transactional resource action that locks the task before
   checking state and inserting the TODO.
4. Add tests for both Ash and direct-SQL admission after task completion.

Acceptance criteria:

- No incomplete TODO can be attached to a completed task.
- Completion and concurrent TODO admission cannot race into an invalid state.

### PC-03 — High: task-to-board workflow membership is not enforced

The board-membership trigger verifies that `column_id` belongs to `board_id`.
It does not verify that the board belongs to the same workflow as the task.

A task in workflow A can therefore be assigned to a valid board and column
owned by workflow B.

Evidence:

- `lib/orchestrator/workflows/task.ex:52`
- `lib/orchestrator/workflows/task.ex:113`
- `lib/orchestrator/workflows/board.ex:20`
- `priv/repo/migrations/20260727144812_add_kanban_board_metadata.exs:163`

Impact:

- Typed project/roadmap/workflow membership can be contradicted by the Kanban
  projection.
- Board queries can expose tasks from another workflow.
- Workflow-scoped authorization added later would inherit an unsafe
  cross-boundary association.

Remediation:

Extend the database trigger to enforce both:

```text
column.board_id = task.board_id
board.workflow_id = task.workflow_id
```

Mirror the check in the Ash action for clearer operator errors, while retaining
the database trigger as the authoritative invariant.

Acceptance criteria:

- Ash and raw SQL both reject cross-workflow board assignment.
- Regression tests cover valid same-workflow and invalid cross-workflow cases.

### PC-04 — Medium: column state and lifecycle state can diverge

`BoardColumn.task_state` declares a lifecycle state for each column, but task
board assignment does not validate or update `Task.state`. Task lifecycle
transitions likewise do not update or validate `column_id`.

Examples of currently representable contradictions include:

- a queued task in an in-progress column
- an in-progress task in a completed column
- a completed task left in a ready column

Evidence:

- `lib/orchestrator/workflows/board_column.ex:16`
- `lib/orchestrator/workflows/task.ex:24`
- `lib/orchestrator/workflows/task.ex:113`
- `lib/orchestrator/workflows/task.ex:130`

Impact:

- There are two independently writable representations of task state.
- Board views and lifecycle queries can disagree.
- Drag-and-drop behavior has no defined governance semantics.

Remediation:

Choose and enforce one model:

1. Columns are derived views of `Task.state`; or
2. Moving a task to a column invokes a governed lifecycle transition.

Do not permit direct, independent writes to both state representations.

Acceptance criteria:

- Board position and lifecycle state cannot disagree.
- Illegal drag-and-drop transitions fail with the same lifecycle rules as the
  CLI.

### PC-05 — Medium: Kanban features are not operable through the canonical CLI

The canonical CLI displays task board metadata, but it cannot:

- create or list boards
- create or list columns
- move a task between columns
- update rank, priority, due date, assignees, labels, or custom fields
- create or evaluate saved filters

These operations currently require direct Ash calls.

Evidence:

- `lib/orchestrator/cli/command.ex:4`
- `lib/orchestrator/cli/executor.ex:16`
- `lib/orchestrator/cli/executor.ex:177`

Impact:

- The host policy names the CLI as the supported automation interface, but the
  new model cannot be administered through it.
- Operators may resort to ad hoc database or application calls.
- Important invariant and error-handling behavior is not exercised through the
  supported interface.

Remediation:

Add governed CLI commands for board, column, task-move, metadata, and saved
filter operations. Ensure all mutations call explicit Ash actions rather than
raw SQL.

### PC-06 — Medium: concurrent TODO admission is race-prone

`create_or_read_todo/3` performs a read, counts existing TODOs, and assigns
`length(todos) + 1`. The operation is not transactional or locked.

Concurrent requests can:

- calculate the same position for different TODOs
- both observe that the same content-addressed TODO is absent
- produce avoidable unique-constraint failures

Evidence:

- `lib/orchestrator/cli/executor.ex:160`
- `lib/orchestrator/workflows/todo.ex:28`

Impact:

- Valid concurrent operator requests can fail nondeterministically.
- The content-addressed ID does not provide reliable idempotency under race.

Remediation:

- Allocate positions transactionally while locking the owning task.
- Use conflict-aware insertion for the stable TODO identity.
- Return the existing TODO on an identity conflict.
- Add concurrent same-body and different-body tests.

### PC-07 — Medium: cancellation reason is optional

The CLI accepts `task cancel ID` without a reason. The transition action
requires a reason for `waiting`, but not for `cancelled`.

This conflicts with the active host workflow, which specifies
`orchestrator task cancel ID REASON`.

Evidence:

- `lib/orchestrator/cli/command.ex:14`
- `lib/orchestrator/workflows/task.ex:147`
- `lib/orchestrator/workflows/task.ex:236`

Impact:

- Terminal cancellation can lack an audit explanation.
- CLI behavior and host governance disagree.

Remediation:

Remove the reasonless parser form and require a nonblank reason in the Task
transition action so non-CLI callers are governed identically.

### PC-08 — Medium: README documents the retired authority state

The README still says that Tuxedo remains authoritative during migration and
documents ledger import as a normal operator command. Live authority is Ash,
legacy executables are retired, and imports are intentionally rejected.

Evidence:

- `README.md:52`
- `README.md:62`

Impact:

- Operators may attempt an invalid or unsafe legacy workflow.
- New maintainers receive contradictory authority guidance.

Remediation:

Rewrite the authority section as post-cutover documentation. Mark the ledger
and import path as historical/disabled, document the cutover timestamp, and
identify parity as a read-only historical verification command only if it
remains intentionally supported.

### PC-09 — Low: Kanban and filter validation is shallow

Current validation checks basic shapes but not sufficient semantics:

- saved-filter keys are allowlisted, but value types and allowed states are not
- custom `date` values need only be strings
- priority and rank have no domain constraints
- labels, assignees, custom-field names, and collection sizes are unbounded
- `board_columns.task_state` is plain text without a PostgreSQL check constraint

Evidence:

- `lib/orchestrator/workflows/saved_filter.ex:41`
- `lib/orchestrator/workflows/task.ex:188`
- `priv/repo/migrations/20260727144812_add_kanban_board_metadata.exs:121`

Impact:

- Invalid or operationally expensive metadata can persist.
- Raw SQL can bypass Ash enum casting.
- Future filter evaluation must handle inconsistent stored shapes.

Remediation:

Define schemas and limits for every filter and metadata field. Add PostgreSQL
checks for finite enums and simple numeric ranges where practical.

## Positive observations

### Database-grade dependency integrity

Dependency edges are protected by:

- same-workflow enforcement
- endpoint existence checks
- cycle detection
- per-workflow advisory transaction locking
- foreign keys and unique constraints

This is the strongest part of the persistence model and a good pattern for the
remaining authority and Kanban invariants.

### Optimistic concurrency control

Task revision, lifecycle transition, workflow definition replacement, board
revision, and board metadata updates use optimistic locking. Dedicated
concurrency tests verify stale-write rejection.

### Safe post-cutover import behavior

With the live authority row set to `ash`, ledger import fails closed. Imported
dependency reconciliation is provenance-aware, and native edges are preserved.

### Useful regression coverage

The suite includes:

- CLI parsing and database integration tests
- migration-upgrade testing
- direct-SQL persistence-invariant tests
- concurrent dependency and metadata tests
- authority/import regression tests
- board metadata and saved-filter tests

### Compact domain model

The primary hierarchy remains understandable:

```text
Project → Roadmap → Workflow → Task → TODO
                              └→ Board → Column
```

No parallel issue table or competing task resource was introduced.

## Test and verification results

The following commands passed using the repository-pinned Erlang/Elixir
runtime:

```sh
mix test
mix compile --warnings-as-errors
mix format --check-formatted
mix ash_postgres.generate_migrations --check
mix escript.build
git diff --check
```

Results:

- 37 tests
- 0 failures
- warnings-as-errors compilation passed
- formatting passed
- migration drift passed
- escript build passed
- Git diff integrity passed
- repository working tree was clean at audit time

All nine migrations were applied to the live development database.

Live authority check:

```text
mode       ash
cutover_at 2026-07-27 12:00:27.831082 UTC
```

Passing tests do not invalidate the findings above; the affected adversarial
and cross-model cases are not currently represented in the suite.

## Prioritized remediation plan

### Priority 0 — preserve authority safety

1. Make `ash` authority irreversible in PostgreSQL.
2. Protect the cutover timestamp.
3. Add reversal and import-reenable regression tests.

### Priority 1 — restore hard task invariants

1. Prevent TODO admission after terminal task states.
2. Serialize TODO admission against completion.
3. Enforce task workflow equals board workflow.
4. Define and enforce lifecycle-to-column semantics.

### Priority 2 — align the supported operator interface

1. Add canonical CLI operations for Kanban metadata.
2. Require cancellation reasons everywhere.
3. Update README authority and legacy-tool guidance.

### Priority 3 — harden metadata quality

1. Add typed saved-filter value schemas.
2. Validate dates, priorities, ranks, arrays, and custom-field names.
3. Add database constraints for finite board-column states.
4. Add adversarial and concurrency regression tests.

## Final assessment

Orchestrator is operational and its automated gate is healthy. Its dependency
and optimistic-locking foundations are credible. The remaining weakness is
that newer governance claims are stronger than their persistence guarantees:
authority is described as one-way but is reversible, completion is described
as evidence-backed but can be invalidated later, and Kanban is described as a
unified task projection without enforcing workflow or state coherence.

Remediating PC-01 through PC-04 would materially improve the system from a
working post-cutover implementation to a defensible authoritative control
plane.
