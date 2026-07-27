# Codebase Audit Report

**Project:** Orchestrator
**Audit date:** 2026-07-27
**Scope:** Application source, project configuration, database migrations, resource snapshots, tests, Git tracking behavior, and packaged CLI
**Review focus:** Correctness, data integrity, security, operability, maintainability, and test coverage

## Executive Summary

The audit identified six material findings: one critical, three high-severity, and two medium-severity issues. All six were corrected on 2026-07-27 and now have executable regression coverage.

Application source is visible to Git, Ash optimistic locks reject stale task and workflow updates, PostgreSQL rejects cross-workflow and cyclic dependency edges (including concurrent opposing inserts), the hierarchy migration backfills pre-existing workflows, production database configuration comes from the environment, and PostgreSQL-backed integration tests exercise these boundaries.

## Severity Summary

| Severity | Count |
|---|---:|
| Critical | 1 |
| High | 3 |
| Medium | 2 |
| Low | 0 |

## Findings

**Current status:** ORC-001 through ORC-006 resolved. The original observations below are retained as the audit record; remediation evidence appears under each finding and in the final verification section.

### ORC-001: Application source is ignored by Git

**Severity:** Critical
**Category:** Source control / release integrity
**Location:** `.gitignore:4`

The ignore rule:

```gitignore
orchestrator
```

is not anchored to the repository root. Git therefore applies it to both the packaged `orchestrator` executable and the `lib/orchestrator/` directory.

The implementation currently contains 24 Elixir source files beneath that directory, but `git status --untracked-files=all` does not report them. A commit or build reconstructed from Git could omit the complete application implementation while retaining tests, migrations, configuration, and documentation.

**Impact**

- Application source may be lost or excluded from review.
- CI and deployment checkouts may be unable to compile the project.
- The packaged executable may become the only surviving implementation artifact.
- Code review and supply-chain traceability are undermined.

**Recommendation**

Anchor the executable rule:

```gitignore
/orchestrator
```

Then confirm that all intended `lib/orchestrator/**/*.ex` files appear in `git status` and add them to version control.

**Priority:** Immediate, before any commit or release.

**Remediation:** Resolved. The executable ignore entry is anchored as `/orchestrator`; `git status --untracked-files=all` reports every `lib/orchestrator/**/*.ex` source file and `git check-ignore` does not match them.

---

### ORC-002: Optimistic locking is not enforced

**Severity:** High
**Category:** Concurrency / data integrity
**Locations:**

- `lib/orchestrator/workflows/task.ex:80`
- `lib/orchestrator/workflows/task.ex:86`
- `lib/orchestrator/workflows/workflow.ex:44`

Task revisions, task transitions, and workflow-definition replacements increment `lock_version`, but none of these actions require an expected version from the caller or condition the database update on the previously read version.

Incrementing a counter alone does not provide optimistic concurrency control. Two clients can read version 1, submit conflicting updates, and both succeed. The later update can overwrite the earlier one while producing a plausible final version number.

This conflicts with the README claim that tasks provide optimistic versioning.

**Impact**

- Concurrent task revisions can silently lose data.
- Competing lifecycle transitions can both be accepted based on stale state.
- Workflow definitions can be replaced without detecting intervening changes.
- Auditability is weakened because `lock_version` suggests stronger protection than is present.

**Recommendation**

- Require callers to supply the version they observed.
- Apply an atomic update predicate such as `WHERE id = ? AND lock_version = ?`.
- Increment the version in the same database statement.
- Return a distinct stale-write or conflict error when no row matches.
- Add concurrent-update tests for task revision, transition, and workflow replacement.

**Remediation:** Resolved. The task `revise` and `transition` actions and workflow `replace_definition` action use `optimistic_lock(:lock_version)`. PostgreSQL updates predicate on the observed version and Ash returns `StaleRecord` on conflicts. Database tests cover task revision, lifecycle transition, and workflow replacement.

---

### ORC-003: Dependency edges can cross workflow boundaries

**Severity:** High
**Category:** Relational integrity / authorization boundary
**Locations:**

- `lib/orchestrator/workflows/dependency.ex:23`
- `priv/repo/migrations/20260727003858_add_orchestration_hierarchy.exs:104`

A dependency contains foreign keys to a predecessor task and successor task. The database prevents a task from depending on itself and prevents duplicate edges, but it does not require both tasks to belong to the same workflow.

The persisted graph can therefore connect otherwise unrelated workflows. Database records can also form dependency cycles; acyclicity is validated only for the separate embedded workflow-definition structure.

**Impact**

- One workflow may become blocked by or coupled to an unrelated workflow.
- Scheduling and readiness calculations may cross authority boundaries.
- Persisted dependency graphs may contradict validated workflow definitions.
- Cyclic database dependencies can make work permanently unschedulable.

**Recommendation**

- Model `workflow_id` on dependency edges and enforce consistency with both task endpoints.
- Prefer database-enforced composite foreign keys where practical.
- Validate same-workflow membership transactionally during dependency creation.
- Define one authoritative relationship between embedded definitions and persisted task edges.
- Reject cycles when inserting or changing persisted dependencies.
- Add tests covering cross-workflow edges, cycles, duplicates, and concurrent insertion.

**Remediation:** Resolved. Dependency edges carry a database-required `workflow_id`. A PostgreSQL trigger derives it from both endpoints, rejects cross-workflow edges, takes a transaction-scoped advisory lock per workflow, and uses a recursive query to reject cycles. Tests cover cross-workflow edges, sequential cycles, concurrent opposing inserts, and foreign-key deletion behavior.

---

### ORC-004: Hierarchy migration is unsafe for existing workflow rows

**Severity:** High
**Category:** Database migration / availability
**Location:** `priv/repo/migrations/20260727003858_add_orchestration_hierarchy.exs:11`

The preceding migration creates the `workflows` table and permits rows to be inserted. The hierarchy migration later adds `name` and `roadmap_id` as non-null columns without defaults or a backfill.

PostgreSQL will reject this alteration when the table contains existing rows because those rows cannot satisfy the new non-null constraints.

**Impact**

- Deployment can fail during migration.
- Application startup or rollout may be blocked.
- Manual data surgery may be required during an incident.
- The migration is safe only for an empty database, an assumption that is not documented or enforced.

**Recommendation**

Use a staged migration:

1. Add the new columns as nullable.
2. Create or identify the required parent records.
3. Backfill all existing workflows.
4. Verify that no null values remain.
5. Add foreign keys and non-null constraints.
6. Replace the old uniqueness constraint only after the backfill is valid.

Add an upgrade test that applies migrations to a database containing workflow rows created under the previous schema.

**Remediation:** Resolved. The hierarchy migration now creates the parent hierarchy first, adds workflow columns nullable, creates a deterministic `legacy-import` project/roadmap, backfills existing rows, and only then applies foreign-key and non-null constraints. The migration upgrade test creates an isolated database, inserts a workflow under the preceding schema, and migrates it through the current head.

---

### ORC-005: Database configuration is fixed to development values

**Severity:** Medium
**Category:** Security / deployment configuration
**Location:** `config/config.exs:6`

The repository always configures the database as:

- Host: `localhost`
- User: `postgres`
- Database: `orchestrator_dev`
- Port: `5432`

There is no environment-specific runtime configuration, password retrieval, connection URL support, or production TLS configuration.

**Impact**

- A production executable may connect to the wrong database.
- Deployment-specific credentials cannot be supplied cleanly.
- Production startup may fail outside a developer workstation.
- Operators may be tempted to place credentials in tracked configuration.

**Recommendation**

- Add `config/runtime.exs`.
- Read a `DATABASE_URL` or equivalent environment-provided configuration.
- Require production configuration explicitly and fail with a clear message when absent.
- Configure TLS according to the database deployment.
- Separate development and test databases.
- Keep credentials out of source control and packaged artifacts.

**Remediation:** Resolved. Development and test use separate databases; production requires `DATABASE_URL`, supports `DATABASE_SSL`, and accepts `POOL_SIZE` from the environment. No production credential is tracked.

---

### ORC-006: Database invariants lack integration coverage

**Severity:** Medium
**Category:** Testing / regression risk
**Locations:**

- `test/orchestration_dsl_test.exs:49`
- `test/workflow_definition_test.exs:7`
- `test/cli_test.exs:7`

The current tests primarily inspect Ash metadata and exercise pure parsing or validation behavior. The dependency constraint test confirms that constraint metadata exists, but does not insert invalid records into PostgreSQL.

No integration tests were found for:

- Stale `lock_version` rejection
- Concurrent task transitions
- Cross-workflow dependency rejection
- Persisted graph cycles
- Migration upgrades with existing rows
- Foreign-key deletion behavior
- CLI commands that read from or write to PostgreSQL
- Transactional behavior when task admission partially fails

**Impact**

- Declared invariants may not match actual database behavior.
- Migration regressions can reach deployment undetected.
- Concurrency defects are unlikely to be caught before production.

**Recommendation**

- Add a test-only repository configuration and SQL sandbox.
- Exercise constraints through real inserts and updates.
- Add migration upgrade fixtures with pre-existing data.
- Test concurrent stale writes and lifecycle transitions.
- Run the database integration suite in CI against the minimum supported PostgreSQL version.

**Remediation:** Resolved locally. The test suite uses a dedicated PostgreSQL test database and SQL sandbox. It exercises stale writes, lifecycle concurrency, workflow replacement, cross-workflow edges, persisted and concurrent cycles, migration upgrades with existing data, foreign-key deletion behavior, and CLI database admission/readback.

## Positive Observations

- Task identifiers use cryptographically strong random entropy and validate calendar timestamps.
- Task kinds and task types use explicit allowlists rather than accepting arbitrary execution mechanisms.
- The embedded workflow-definition validator checks duplicate identifiers, unknown dependencies, self-dependencies, duplicate dependencies, empty graphs, and cycles.
- Topological ordering is deterministic because ready identifiers and dependents are sorted.
- The lifecycle transition table fails closed for unknown or disallowed transitions.
- Database migrations define stable identities and foreign keys throughout most of the hierarchy.
- SQL helper functions set an empty `search_path`, reducing schema-resolution risk.

## Verification Performed

- Generated and queried the repository code graph as required by project policy.
- Reviewed application source, configuration, migrations, tests, snapshots, and Git ignore behavior.
- Confirmed with `git check-ignore` that `.gitignore:4` excludes `lib/orchestrator/`.
- Inspected the packaged escript and confirmed that it contains compiled `Orchestrator.*` modules.
- Successfully exercised:
  - `./orchestrator id`
  - `./orchestrator validate-id tsk-20260727T012351Z-ea5ba1b1`
- Attempted to run `mix test`.

## Remediation Verification

- `MIX_ENV=test mix test` — 21 tests, 0 failures.
- Focused PostgreSQL suite — 7 tests, 0 failures.
- `mix compile --warnings-as-errors` — passed.
- `mix ash_postgres.generate_migrations --check` — passed.
- `mix ash.migrate` — applied the graph-integrity migration to `orchestrator_dev`.
- `mix escript.build` and `./orchestrator id` — passed.
- `git check-ignore lib/orchestrator/workflows/task.ex` — no match.

The earlier Hex/OTP limitation is no longer present.

## Recommended Remediation Order

1. Fix `.gitignore` and place the entire source tree under version control.
2. Repair the development toolchain and establish a clean, reproducible test run.
3. Implement true optimistic concurrency checks.
4. prevent cross-workflow and cyclic persisted dependencies.
5. Replace the unsafe hierarchy migration with a staged upgrade.
6. Add production runtime configuration.
7. Add PostgreSQL-backed integration and migration tests.

## Overall Assessment

The six audited defects are corrected and regression-tested. Ledger import may proceed as the next controlled phase, but authority cutover still remains gated on import parity and rollback proof.
