# PostgreSQL 19 staging current-state audit

Date: 2026-08-11 UTC

Governing task: `tsk-20260811T173357Z-51102d3c`

## Verdict

The PostgreSQL 19 feature line is integrated on
`staging/postgres19-mama-20260811` from Mama's schema-compatible hotfix
baseline `8f0d759cb1c349aad720c889500b49b19c40cba7`. The merge includes the full
prerequisite chain through
`968f25596d4e5eac2f9817c4cdcef06c4370a6eb`; it does not extract the property
graph files without their actor, custody, SOP, and schema dependencies.

The staging branch passes source and PostgreSQL 19 development checks, but it
is not approved for production deployment. Mama still runs PostgreSQL 16.14
and has 24 migrations through `20260730192013`. The staged release has 33
migrations through `20260810170000`.

## Staged migration set

1. `20260805200255` adds revisions and lock versions.
2. `20260806033446` adds the actor and grant registry.
3. `20260807031037` versions SOP acknowledgments.
4. `20260810030458` adds immutable ledger import receipts.
5. `20260810034300` adds authority-instance identity.
6. `20260810121915` adds artifact custody requirements and receipts.
7. `20260810133000` hardens the artifact custody trigger.
8. `20260810143000` creates the PostgreSQL 19 task-dependency property graph.
9. `20260810170000` prevents dependency workflow metadata changes.

The corresponding features include scoped actor authorization, governed
revisions, versioned SOP acknowledgment, durable outbox and ledger controls,
artifact custody, task dependency graph queries, remote-authority refusal, and
lifecycle-reason clearing.

## Verification

- `mix format --check-formatted`: passed.
- `MIX_ENV=test mix compile --warnings-as-errors`: passed.
- Focused migration, graph, authorization, authority, and database suite: 82
  tests, 0 failures.
- Full suite: 249 tests, 0 failures.
- `mix ash_postgres.generate_migrations --check`: passed without drift.
- `mix ecto.migrations`: all 33 migrations are applied in the development
  PostgreSQL 19 database.
- The migration test removes and reapplies the property graph and its integrity
  trigger while preserving the historical hierarchy fixture.
- A fresh compiled test CLI created a Project, Roadmap, two-node Workflow,
  Task, and TODO; exercised `propose -> queue -> ready -> start`; completed the
  TODO and task; and retained regression evidence. The proof task is
  `tsk-20260811T174146Z-bacf318a` in the isolated test database.

## Current live state and blockers

1. **Blocker: engine incompatibility.** Mama runs PostgreSQL 16.14. Migration
   `20260810143000` uses `CREATE PROPERTY GRAPH`, so the staged migration set
   cannot run on Mama's current engine.
2. **Blocker: no snapshot rehearsal.** The complete 24-to-33 migration jump has
   not been rehearsed against a fresh, checksum-verified Mama database snapshot
   on PostgreSQL 19. Development fixtures do not prove production data
   compatibility or runtime duration.
3. **Concern: release provenance.** Mama's service exposes release version
   `0.1.0` but no Git commit or tree identity. Operational records identify
   `8f0d759...` as the hotfix source, but the running artifact cannot attest
   that identity itself. Exact deployed-byte parity is therefore unproven.
4. **Concern: actor cutover.** The actor-registry migration creates an empty
   registry. The production transition needs a proved genesis-actor and
   least-privilege grant sequence before normal remote CLI traffic resumes.
5. **Concern: rollback is snapshot-based.** Ledger receipt and authority
   identity migrations do not define `down/0`; artifact custody intentionally
   refuses rollback after custody data exists. The release procedure must use
   a frozen, verified snapshot and explicit authority switch rather than claim
   general Ecto rollback support.
6. **Observation: test CLI bootstrap.** A standalone `MIX_ENV=test` escript
   expects the configured `test-system` actor. An empty isolated test database
   must seed that test-only actor before workflow dogfood. This does not affect
   the production genesis path, where the default actor is deliberately unset.

## Twelve-Factor baseline

Reviewed upstream `twelve-factor/twelve-factor` `main` at
`655b020ac25eac8f912ccc845094ec16cdf6b30b`.

- Codebase and dependencies are versioned in one repository.
- Production database and service settings are environment-backed; the
  authority marker remains a host control outside the application factors.
- Build, release, and run are operationally separated, but the release lacks
  immutable source-commit metadata. This is the material release-factor
  deviation.
- PostgreSQL is a backing service. Mama's PostgreSQL 16 versus staged
  PostgreSQL 19 difference is the material environment-parity deviation.
- The service is stateless apart from PostgreSQL and the bounded artifact
  store. It uses a Unix socket for the operator CLI and journald for logs.
- Schema migration and actor genesis are administrative processes and require
  an explicit, governed cutover procedure.

## Required next gate

Before deployment, create a separate governed cutover task that upgrades or
replaces Mama's PostgreSQL engine through a verified rollback-preserving path,
rehearses the full migration and actor bootstrap from a fresh Mama snapshot,
builds a release carrying immutable Git identity, verifies service and CLI
behavior, and records the rollback decision. This audit grants no deployment
authority.
