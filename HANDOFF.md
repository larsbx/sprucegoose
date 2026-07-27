# Orchestrator Authority-Cutover Handoff

Status: Historical — cutover completed; current findings are in
`POST_CUTOVER_AUDIT_REPORT.md`

Date: 2026-07-27 UTC

## Executive status

The audit remediation has been implemented and independently rechecked. All
eight findings from `REAUDIT_REPORT.md` are addressed in the current working
tree.

The full verification gate passes:

- 32 tests, 0 failures
- compilation with warnings treated as errors
- formatting check
- Ash/Postgres migration-drift check
- escript build
- Git diff whitespace/integrity check

The remediation is not committed. `REAUDIT_REPORT.md`, this handoff, the
authority module, the authority/dependency migration, its resource snapshot,
and the regression test are untracked at handoff time. Other remediation files
are modified in the working tree.

## Toolchain

The repository pins:

- Erlang/OTP 28.3.1
- Elixir 1.19.5-otp-28

Initialize the operator shell so `erl`, `elixir`, and `mix` resolve to the
versions pinned in `.tool-versions`, then run Mix commands directly. Confirm
the resolved versions before deployment or cutover.

## Audit remediation

### Authority and ledger safety

`Orchestrator.Authority` reads the durable singleton authority record.
`Ledger.import/1` is accepted only while the authority mode is `tuxedo`.
After the authority record changes to `ash`, imports fail closed.

Before cutover, Tuxedo refreshes:

- update only tasks carrying `legacy_source = "tuxedo"`
- refuse to overwrite native Ash tasks
- merge legacy provenance into `input` instead of replacing native metadata
- increment `lock_version`, invalidating stale writers
- run transactionally with exact parity verification

### Dependency reconciliation

Dependency edges now carry a `source` value. A ledger refresh removes and
reconstructs only `tuxedo` edges. Native Ash edges remain intact.

### Lifecycle governance

Lifecycle movement is explicit:

```text
task propose
task queue
task ready
task start
task wait
task done
task cancel
```

`task start` accepts only a ready task and verifies that all predecessors are
complete. The CLI no longer searches for and silently traverses a multi-state
path.

Wait and cancellation reasons are stored in the same optimistic-locking update
as the state transition. Diagnosis completion requires:

- a `finding` reference
- a `regression` reference
- an `sop` reference
- every subordinate TODO to be complete

Task JSON now exposes references, wait/cancellation reasons, lock version, and
legacy-import provenance.

### Fail-closed parsing

Ledger parsing rejects unknown task schemas, task types, and task statuses.
Legacy records that omit those optional fields retain the documented legacy
defaults.

## Verification commands

From the repository root:

```sh
mix test
mix compile --warnings-as-errors
mix format --check-formatted
mix ash_postgres.generate_migrations --check
mix escript.build
git diff --check
```

Last result: all commands passed; the test suite reported 32 tests and zero
failures.

The dedicated regression contract is:

```sh
mix test test/reaudit_regression_test.exs
```

It covers:

- refresh locking and native metadata preservation
- import rejection after Ash cutover
- stale imported-edge removal and native-edge preservation
- explicit lifecycle gates
- atomic wait/cancel reasons
- diagnosis evidence and TODO completion requirements
- task JSON visibility

## Deployment and cutover sequence

Do not retire Tuxedo or `taskctl` until every step below succeeds in the target
environment.

1. Review and commit the complete working tree as one coherent remediation.
2. Deploy the application with the pinned Erlang/Elixir toolchain.
3. Apply the new database migration:

   ```sh
   mix ecto.migrate
   ```

4. Confirm the authority row exists and is still `tuxedo`.
5. Perform the final ledger import from the unchanged authoritative
   `todo.txt`.
6. Run exact ledger parity and preserve its output as cutover evidence.
7. Exercise Ash CLI task reads and lifecycle commands against the target
   database.
8. In one controlled database operation, change the singleton authority mode
   from `tuxedo` to `ash` and set `cutover_at`.
9. Prove that a subsequent ledger import is rejected.
10. Re-run the test/compile/format/migration/escript/diff gate on the deployed
    revision.
11. Only after the above evidence is retained, retire Tuxedo and `taskctl`
    entry points according to the approved operational procedure.

The authority migration intentionally initializes the mode as `tuxedo`; merely
deploying or migrating does not perform the cutover.

## Rollback boundary

Before authority transfer, the unchanged `todo.txt` remains the recovery
source, and the transactional import can reconstruct the imported Ash data.

After authority changes to `ash`, ledger import is deliberately disabled.
Do not switch authority back casually: post-cutover Ash-native changes may not
exist in the legacy ledger. A rollback after Ash becomes writable requires an
explicit reconciliation and data-preservation plan, not only an authority-row
update.

## Files central to the remediation

- `lib/orchestrator/authority.ex`
- `lib/orchestrator/ledger.ex`
- `lib/orchestrator/cli/command.ex`
- `lib/orchestrator/cli/executor.ex`
- `lib/orchestrator/workflows/task.ex`
- `lib/orchestrator/workflows/dependency.ex`
- `priv/repo/migrations/20260727104241_harden_authority_and_dependency_import.exs`
- `test/reaudit_regression_test.exs`
- `REAUDIT_REPORT.md`

## Immediate owner action

Review the uncommitted diff and stage the handoff, reports, source changes,
migration, resource snapshot, and tests together. The next operational decision
is whether to schedule the controlled authority transfer; this document does
not itself execute that destructive cutover or retire legacy tooling.
