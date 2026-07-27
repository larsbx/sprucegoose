# Orchestrator Post-Cutover Remediation Report

Status: Implemented — independent re-audit pending

Date: 2026-07-27 UTC  
Source audit: `POST_CUTOVER_AUDIT_REPORT.md`  
Remediation revision: `f1d1be8` (`Harden post-cutover authority and Kanban invariants`)  
Task: `tsk-20260727T190907Z-e259d034`

## Finding disposition

| Finding | Disposition | Evidence |
| --- | --- | --- |
| PC-01 | Implemented | PostgreSQL permits only the initial `tuxedo → ash` cutover and rejects every later mode or timestamp mutation; direct-SQL reversal tests pass. |
| PC-02 | Implemented | TODO insertion locks the owning task and rejects terminal states; task completion has a database guard against incomplete TODOs. |
| PC-03 | Implemented | Ash and PostgreSQL require task workflow, board workflow, column board, and task/column state to agree. |
| PC-04 | Implemented | A governed move changes lifecycle and placement atomically; ordinary lifecycle transitions align to the unique column for the target state; direct divergence is rejected. |
| PC-05 | Implemented | The canonical CLI now creates/lists boards and columns, moves tasks, updates metadata, creates/lists/applies filters, and uses explicit Ash actions. |
| PC-06 | Implemented | TODO admission uses a per-task transaction lock, returns the existing stable identity, allocates distinct positions, and is race-tested against completion. |
| PC-07 | Implemented | Parser and Task transition action require a nonblank cancellation reason. |
| PC-08 | Implemented | README describes Ash authority, irreversible cutover, retired legacy tooling, historical parity, and current Kanban commands. |
| PC-09 | Implemented | Ash validates filter value schemas, ISO dates, priority/rank bounds, collection/name limits, and custom-field limits; PostgreSQL constrains priorities, ranks, collection sizes, unique board states, and finite column states. |

## Verification

Focused post-cutover and CLI gate:

```sh
mix test test/post_cutover_hardening_test.exs test/cli_test.exs \
  test/reaudit_regression_test.exs
```

Result: 15 tests, 0 failures before the final expanded race coverage; the
dedicated post-cutover suite then passed 5 tests with completion/TODO and
same/different-body concurrency cases.

Full gate:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix ash_postgres.generate_migrations --check
mix escript.build
git diff --check
```

Result: 43 tests, 0 failures. Compilation, formatting, migration drift,
escript build, and Git diff checks passed.

Migration `20260727191241_harden_post_cutover_invariants.exs` is applied to the
development and test databases. The live authority remains `ash`; ledger
import remains disabled.

## Re-audit boundary

This record documents implementation and regression evidence. It does not
rewrite the historical audit or independently declare the findings resolved.
An independent re-audit should verify revision `f1d1be8`, exercise each
acceptance criterion, and map PC-01 through PC-09 to final lifecycle states.

