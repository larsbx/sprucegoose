# SpruceGoose Current-State Handoff

Status: Identity seam remediated and committed; not yet activated in production write paths

Date: 2026-07-30 UTC

Canonical repository: `/home/admin-papa/sprucegoose`

Branch: `main`

Current handoff commit base: `8a7a617`

## Executive status

The interrupted identity-seam work has been repaired, made reproducible, tested,
committed, and closed in authoritative SpruceGoose governance.

Two critical defects from the audit are fixed:

- fixed-width derivation inputs now reject overflow instead of silently wrapping
  to colliding encodings;
- local Ed25519 provisioning retains the private seed with the public key, so a
  newly provisioned peer can prove ownership later.

The seam remains deliberately inactive outside its own modules and tests. Task,
inbox, TODO, outbox, and surrogate-table identifiers still use their existing
schemes. Swapping those write paths, adding `payload_b3`, and deriving outbox
`event_id` are a separate phase and were explicitly excluded from the completed
identity task.

## Repository state

Relevant commits, newest first:

- `8a7a617` — Prove identity sequence restart durability
- `41065ee` — Add durable identity derivation seam
- `316997a` — Add red historical graph migration regression
- `1643c93` — Harden dependency and outbox invariants
- `ba79baf` — Add BLAKE3 dependency with reference vector tests
- `8ca72be` — Record identifier model specification (diagnosis)

The worktree was clean at handoff preparation.

The rebuilt `sprucegoose` escript was generated from the remediated source on
2026-07-29 at 22:06:21 UTC. Use this binary, not the retired or captured
`orchestrator` escript.

## Identity seam

### Derivation invariants

`SpruceGoose.Derive` provides:

- length-prefixed tuple-field encoding;
- BLAKE3 namespace-separated hashing;
- big-endian `u32` and `u64` encoding;
- deterministic RFC 9562 UUIDv7 layout with a 48-bit timestamp and 74 digest
  bits;
- originated and parent-derived identity helpers;
- stable task suffix projection.

The accepted numeric domains are now explicit:

- `u32be/1`: `0..2^32-1`;
- `u64be/1`: `0..2^64-1`;
- `uuid_v7d/2` timestamp: `0..2^48-1`.

Values above those maxima fail with no wrapped output.

### Peer identity and sequence

`SpruceGoose.Identity` defines the adapter contract. The current local adapter
uses:

- a singleton `spruce_goose_identity` row;
- a 32-byte Ed25519 public key as `peer_id`;
- the matching retained 32-byte private seed;
- database constraints for singleton shape, algorithm, and key lengths;
- a trigger making both key halves immutable;
- the non-transactional `spruce_goose_origin_seq` PostgreSQL sequence.

Concurrent first provisioning converges on the winning row. The private seed is
not logged or linked as evidence.

### Upgrade behavior

Migration `20260729145500_add_identity_seam.exs` creates the complete schema for
a fresh database.

Migration `20260729182000_preserve_identity_private_key.exs` upgrades databases
that had already applied the public-only version. It fails closed if a
public-only row exists because no new private key could match that public key.
The verified dev and test databases had no identity row, so both upgraded
without orphaning an identity.

A disposable fresh database was created, migrated from zero, ran the focused
identity suite, and was dropped successfully.

## Verification state

Passing gates:

- focused identity and derivation suite: 24 tests, 0 failures;
- all implemented tests excluding the separately committed intentional-red
  historical-graph regression: 123 tests, 0 failures;
- formatting check;
- development compilation with warnings treated as errors;
- Ash/PostgreSQL migration drift check;
- Git diff whitespace check;
- dev and test migration upgrade;
- disposable fresh-database migration and focused tests;
- escript rebuild;
- compiled-CLI schema/workflow dogfood.

The unfiltered suite is intentionally not green at this handoff. Commit
`316997a` added two red tests in
`test/historical_graph_migration_regression_test.exs`. They call the not-yet-
implemented `SpruceGoose.Knowledge` API. Current result after the restart test
was added is expected to be 125 tests with those same 2 failures. Do not
attribute those failures to the identity seam and do not weaken or delete the
red regression to obtain a green count.

## Compiled-CLI dogfood evidence

The rebuilt CLI created and completed this full chain in the development
database:

- project: `identity-seam-dogfood-20260729`
- roadmap: `identity-seam`
- workflow DAG: `identity-seam-v1`
- task: `tsk-20260729T223019Z-9dadd930`
- TODO: `todo-bc9b2bcd37bdf37f1676c09323e19733`

The task exercised `propose → queue → ready → start → completed`; its TODO was
completed and regression evidence was attached.

## Governance state

Completed identity audit diagnosis:

- `tsk-20260729T175713Z-6627857d`

Completed identity implementation task:

- `tsk-20260729T145111Z-c2959f95`

The implementation task links commits `41065ee` and `8a7a617`, focused/full
regression evidence, dev/test and fresh-database migration proof, dogfood
identities, and the Systemwide SOP digest.

Previously stale completed work was reconciled:

- P1.1 `tsk-20260729T093354Z-d9508883` — completed with its existing five refs;
- P1.2 `tsk-20260729T101831Z-652186d1` — completed with its existing five refs;
- P1.3 `tsk-20260729T102757Z-58638d6e` — completed with its existing five refs;
- P2 `tsk-20260729T123559Z-8c6ced7d` — commit, regression, and SOP evidence
  attached, then completed.

Authoritative task state is PostgreSQL through the compiled `sprucegoose` CLI.
Tuxedo, `taskctl`, `/home/admin-papa/tasks/todo.txt`, historical Graphify output,
and captured `orchestrator` binaries are not current authority.

## Next bounded work

1. Implement the separately committed historical-graph migration contract in
   `SpruceGoose.Knowledge` until the two red tests pass. Keep current canonical
   source and PostgreSQL as authority; historical Graphify data is input only.
2. Admit a separate governed phase before activating derived identity in live
   write paths.
3. In that phase, enumerate every Ash action, CLI path, SQL trigger/default,
   import path, retry path, and concurrency boundary before changing IDs.
4. Add `payload_b3` and deterministic outbox `event_id` with migration/backfill
   and mixed-version compatibility evidence.
5. Decide and document private-key operational custody before signing is
   exposed. Never print, link, or commit the private seed.
6. Rebuild the escript after every source change and dogfood schema or workflow-
   admission changes through a fresh Project → Roadmap → Workflow → Task → TODO
   chain.

## Recovery and operator notes

The local PostgreSQL 16 cluster uses:

- data: `/home/admin-papa/pgdata`
- server binaries: `/home/admin-papa/pglocal/usr/lib/postgresql/16/bin`
- port: `5432`
- Unix socket directory: `/tmp`

It was restarted during remediation using its existing `postmaster.opts`; no
replacement database was created. If it is down, inspect current cluster state
and logs before restarting the same data directory.

For a public-only identity upgrade failure, do not generate a replacement key
and pretend it owns the stored public key. Restore the matching private seed, or
if direct evidence proves the identity was never used, explicitly reset the
unused singleton row before retrying the migration.

## Primary files

- `docs/identifier-model.md`
- `lib/spruce_goose/derive.ex`
- `lib/spruce_goose/identity.ex`
- `lib/spruce_goose/identity/local.ex`
- `priv/repo/migrations/20260729145500_add_identity_seam.exs`
- `priv/repo/migrations/20260729182000_preserve_identity_private_key.exs`
- `test/derive_golden_test.exs`
- `test/identity_local_test.exs`
- `test/historical_graph_migration_regression_test.exs`

## Verification commands

From `/home/admin-papa/sprucegoose` with the pinned asdf toolchain:

```sh
asdf exec mix test test/derive_golden_test.exs test/identity_local_test.exs
asdf exec mix test $(rg --files test -g '*_test.exs' | rg -v 'historical_graph_migration_regression_test.exs')
asdf exec mix format --check-formatted
MIX_ENV=dev asdf exec mix compile --warnings-as-errors
asdf exec mix ash_postgres.generate_migrations --check
asdf exec mix escript.build
git diff --check
```

Run unfiltered `asdf exec mix test` as well; until the knowledge migration is
implemented, its only expected failures are the two intentional-red tests named
above.
