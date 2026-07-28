# SpruceGoose Current-System Audit Remediation

**Date:** 2026-07-28
**Status:** Validated
**Prior report:** `CURRENT_SYSTEM_AUDIT_REPORT.md`
**Audited implementation:** `cd2875aa5cc0345e51ad0053d94ae2dd71a496a1`
**Remediation:** `5e2ddc5`
**Branch:** `main`
**Authority:** SpruceGoose/Ash, authority mode `ash`
**Task:** `tsk-20260728T142801Z-e1e1b46f`
**Runtime:** Erlang/OTP 28.3.1; Elixir 1.19.5-otp-28

## Scope and method

This addendum validates and remediates CSA-01 through CSA-03 from the prior
report. It covers the public Ash Task create, acknowledgment, transition, and
move actions; the CLI adapters; the SOP evidence schema and migration; runtime
path configuration; and focused plus shared regression coverage.

It excludes deployment, publication, remote push, authority changes, legacy
ledger import execution, and unrelated application behavior. No audit finding
authorized those actions.

The managed project graph was queried before source inspection. The findings
were then reproduced from the referenced source and with failing tests before
the implementation changed.

## Finding disposition

### CSA-01 — Resolved

Every public Ash Task path from `ready` to `in_progress` now invokes the shared
resource-level SOP verification. This covers both `:transition` and `:move`;
the CLI check remains an early error path.

Regression coverage corrupts the persisted digest and proves that direct
`Ash.update` calls through both public actions reject the start.

### CSA-02 — Resolved

The public Task create action no longer accepts the exemption, identifier,
path, digest, or acknowledgment timestamp. The public `:acknowledge_sop` action
accepts no caller-supplied evidence. Both actions populate evidence through the
trusted resource change that reads and hashes the configured SOP.

The retired SQL ledger-import path remains the sole grandfathering mechanism
and explicitly writes `sop_gate_required = false`. It remains unavailable
while Ash authority is active.

Regression coverage proves ordinary create and acknowledgment callers cannot
choose an exemption or manufacture evidence.

### CSA-03 — Resolved

Evidence now carries the stable identifier `systemwide-sop`. The deployment
path is selected by `SYSTEMWIDE_SOP_PATH` and retained as audit evidence, but
the database invariant no longer embeds one account-specific absolute path.

Migration `20260728143420_remediate_sop_gate.exs` backfills the stable
identifier on gated rows and replaces the old path-bound constraint. The
migration was applied to both the test and development databases.

Regression coverage creates a task against an alternate configured SOP path
and proves the stable identifier and alternate evidence path persist through
the database constraint.

## Verification

The following commands completed successfully from
`/home/admin-papa/sprucegoose`:

```text
MIX_ENV=test asdf exec mix ecto.migrate
asdf exec mix test test/cli_database_test.exs
8 tests, 0 failures

asdf exec mix ecto.migrate
asdf exec mix test
53 tests, 0 failures

asdf exec mix compile --warnings-as-errors
asdf exec mix format --check-formatted
asdf exec mix ash_postgres.generate_migrations --check
git diff --check
```

The compile, formatting, migration-drift, and whitespace gates exited
successfully.

## Database and recovery state

The development and test databases contain migration
`20260728143420_remediate_sop_gate`. Existing gated task rows were backfilled
with `systemwide-sop`; grandfathered rows remain explicitly exempt. The
migration down path restores the former constraint and removes `sop_id`.

No rollback was required. No production deployment, scheduler change, remote
push, or authority mutation occurred.

## Final verdict

**PASS.** CSA-01 through CSA-03 meet their acceptance criteria at the public
Ash boundary and the database boundary. The Systemwide SOP gate may now be
described as a system-wide SpruceGoose domain control for public Task actions.

Raw SQL by a database owner and private code changes remain outside the public
Ash trust boundary; those capabilities are governed operationally rather than
claimed to be prevented by this resource action.
