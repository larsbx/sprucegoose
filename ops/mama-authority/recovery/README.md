# PostgreSQL 19 and actor-schema recovery (`corr-7`)

## Status and authority

This procedure governs recovery from the actor-aware release/schema/bootstrap mismatch. It is not standing authorization to change production.

Production remains on the schema-compatible pre-actor release until all of the following exist together:

1. a reviewed exact application/recovery tree;
2. a verified PostgreSQL 19 installation artifact;
3. a declared deployment freeze;
4. an immediate prechange physical backup and logical backup;
5. a stopped application and worker plane;
6. a successful PostgreSQL upgrade, migrations, governed actor bootstrap, candidate start, and control suite;
7. preserved rollback artifacts and receipts.

Do not run only `20260806033446_add_actor_registry.exs`. The actor-aware release has nine migrations beyond production, and migrations 32–33 require PostgreSQL 19 property-graph support.

## Verified topology on 2026-08-10

| Role | Host | Account | Verified boundary |
|---|---|---|---|
| Application, database, SOP trust anchor | Mama (`ubuntu-8gb-hil-1`) | `admin-papa` | SpruceGoose and PostgreSQL are user services; PostgreSQL binds locally |
| Controller/build host | Evergreen/Papa (`ubuntu-8gb-evergreen`) | `admin-papa` | Reaches Mama through the configured `mama` SSH alias |
| Production application | Mama | `admin-papa` | Pre-actor commit `8f0d759cb1c349aad720c889500b49b19c40cba7` |
| Production database | Mama | `admin-papa` | PostgreSQL 16.14, database `spruce_goose_dev`, 24 migrations before rehearsal |
| Rehearsal database | Mama | `admin-papa` | Separate data and owner-only socket directories; PostgreSQL uses socket port number `55432`, `listen_addresses=''`, and no TCP listener |
| Rehearsal application | Mama | `admin-papa` | Transient unit `sprucegoose-corr7-pg19.service`, separate release node and CLI socket |

Paths with the same spelling on different hosts are not treated as the same object. Copy and verify each artifact at each host boundary.

## Rehearsal scripts

Run from Mama as `admin-papa`, not against the live data directory:

1. `prepare-pg19-upgrade-rehearsal.sh`
   - requires a governed `CORR7_REHEARSAL_RUN_ID`, recreates the rehearsal root, and emits a compatibility manifest bound to that run, the script hash, log hashes, and both cluster system identifiers;
   - verifies both live services are active/running, derives the actual running postmaster `-D` path, and invokes the canonical PGDATA guard before deleting or recreating the rehearsal root;
   - obtains an online physical clone with `pg_basebackup`;
   - initializes an isolated PostgreSQL 19 target cluster as role `postgres` with owner-only local-socket trust and rejected host authentication;
   - verifies exactly 24 pre-actor migrations;
   - runs `pg_upgrade --check` with explicit old/new binaries and libraries.
2. `run-pg19-upgrade-rehearsal.sh`
   - requires the same run ID and rejects a stale compatibility log, mismatched run manifest, or changed cluster system identifier;
   - canonicalizes configured, running, and candidate PGDATA paths; rejects exact aliases, either ancestor/descendant overlap, every symlink component in the candidate path, every mount point at or below a destructive root, and a candidate resolving on a different enclosing mount from live PGDATA;
   - inventories exact migration versions, extensions, material non-system role attributes including a protected SHA-256 of each password verifier, role-specific and database-global settings, role memberships, and every public table count;
   - injects a disposable database-global setting so `setrole=0` inventory parity is exercised;
   - performs a copy-mode physical upgrade;
   - starts only the isolated PG19 clone with `listen_addresses=''`;
   - requires exact before/after inventory equality;
   - runs staged analysis, stops the clone, and writes a checksummed upgrade evidence manifest.
3. `run-actor-migration-on-pg19-rehearsal.sh`
   - requires the same run ID, `CORR7_EXPECTED_TREE`, and externally recorded `CORR7_EXPECTED_ARCHIVE_SHA256`; verifies archive/client digests, verifies the archive's `CORR7_PROVENANCE` tree, and verifies the preceding upgrade evidence checksums;
   - derives a passwordless private `DATABASE_URL` for synthetic role `postgres` using the owner-only Unix `socket_dir`; host authentication is rejected and no rehearsal TCP listener exists;
   - generates a fresh rehearsal-only signing secret and release cookie and never sources or passes the live token-signing secret or database password to the candidate;
   - binds Genesis to the explicit rehearsal-only actor `recovery-operator`;
   - migrates the exact packaged 24-version prefix to the exact packaged 33-version set with Oban, outbox, MCP, and ledger recovery disabled;
   - requires graph-edge parity with the relational dependency table;
   - starts a distinct transient candidate and waits for a real CLI `version` response;
   - proves unknown-actor refusal, a complete seven-global-grant Genesis human, delegated agent creation with one additional operator grant (eight rows total), unauthorized administration refusal, authorized task access, the exact PostgreSQL advisory-lock blocker relationship, and restart persistence;
   - stops both candidate and isolated database on every exit; only a successful EXIT path may emit `completion-status.txt`, and it does so after proving transient PostgreSQL/application inactivity, live-service activity, and final evidence checksum validity;
   - emits a tree/run/artifact/cluster-bound evidence manifest plus `SHA256SUMS`; interrupted or failed runs have no successful completion receipt.

The scripts use `$HOME/recovery-rehearsal`; they must never resolve the rehearsal data path to `$HOME/pgdata`.

The final evidence package must also contain the exact-tree source gate logs, including a `mix test test/spruce_goose/web/mcp_auth_test.exs --seed 0 --trace` receipt that names the spoofed-client, wrong/missing-scope, and valid-client-ID cases. It must contain the detached review commit payload and verify it with `git hash-object -t commit --stdin`; a manifest assertion or Git archive header alone is insufficient commit custody.

The prior archives `e96b374d6ccb0d068b058a64ed03764594b104d46662aa07c2351d8a8ed107e6`, `9974623b37325ebdb71970e3407b3fe1c20c985880262b2f75b2ab56ae0af8ee`, `7ca8d891caadd9334bd8719d00aa9e24ad9949de3f8bca81a25e16d0034339e2`, and `2f756fdd5d9bdfbd234ef99e753ef51ec94c0421f82286874ebaae500e77dfe1` are rejected because they predate later independent-review corrections. Evidence archives `6aaabcf8a741d4f25bacd183184a27a06bd9ebd51fe152dc97fa13843b8ea674`, `d7f564100408601c6545d84fab042ca9dd7040418569d7c9348ceec447abce78`, and `3e926d69dffb4b9743f32228c7372cffe4cbf3d867c229cccac828ab773b295c`, and source archives `df0ea2a355e66f78b8acb09b2ab4e66d57cb35a6cca599a8f2b36e51b9cb78fd` and `3d4b63b404ddf8f6148211defaea18390ec6000f481d21ef436bd2a2c1f0f8ea`, are retained as superseded historical evidence, not authorization for the corrected tree. The reviewed client remains pinned to SHA-256 `d07cc14bff1d4384176f829d9c130a09e82425bc7326fe5370ffc9785ad6b9b9`. Generate a new release archive only after the final source tree is staged and all gates pass. Add this untracked file to the built release root before archiving:

```text
CORR7_PROVENANCE
head=<FINAL_HEAD>
tree=<FINAL_STAGED_TREE>
```

Run the committed separate-session gate on Evergreen before packaging:

```sh
mix test test/actors_separate_sessions_test.exs \
  --include separate_sessions --seed 0 --max-cases 1
```

Run the normal Mama rehearsal with one fresh run identity and the exact final staged tree:

```sh
export CORR7_REHEARSAL_RUN_ID="corr7-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 8)"
export CORR7_EXPECTED_TREE='<FINAL_STAGED_TREE>'
export CORR7_EXPECTED_ARCHIVE_SHA256='<FINAL_RELEASE_ARCHIVE_SHA256>'
$HOME/recovery-rehearsal/prepare-pg19-upgrade-rehearsal.sh
$HOME/recovery-rehearsal/run-pg19-upgrade-rehearsal.sh
$HOME/recovery-rehearsal/run-actor-migration-on-pg19-rehearsal.sh
```

All three commands must receive the same exported run ID. The actor phase must receive the exact tree embedded in `CORR7_PROVENANCE`. Do not reuse an interrupted run ID or any compatibility/evidence directory from another run. A clean run is incomplete unless `$HOME/recovery-rehearsal/corr7-pg19-evidence/completion-status.txt` exists, records that run ID, `exit_status=0`, `cleanup=PASS`, both transient services inactive, both live services active, and verifies through the colocated `SHA256SUMS`.

Copying a same-named archive or script to Mama is not proof of identity. Verify the SHA-256 on Papa and again on Mama before execution.

## Rehearsal evidence

Superseded trees `2367803a719bb48f268103d90121a42ce62c67e7` and `3f0206aaa8842d000bc5453c4a248d3530d3e672` produced the following historical clean-run observations. They demonstrate the disposable path but do not satisfy final actor review or authorize the current corrected tree; all observations, signal receipts, and the clean completion receipt must be regenerated after the current corrections are frozen:

```text
physical_clone_version=16.14 (Ubuntu 16.14-0ubuntu0.24.04.1)
physical_clone_migrations=24
pg_upgrade_check=PASS
live_services=active
upgraded_clone_version=19beta2
inventory_match=PASS
analyze_in_stages=PASS
live_services=active
migrations=24->33
tasks=581->581
graph_edges=57 relational_edges=57
actors=2 actor_grants=8
authorization_controls=PASS
registry_write_lock_probe=PASS
restart_control=PASS
live_services=active
```

The task count is evidence from that snapshot, not a fixed production invariant. Production may continue to change before the freeze; recapture all counts after freeze.

## Signal-interruption controls

The probe-only hold variables are validated integers from `0` through `120` and default to `0`; normal rehearsals do not pause. Do not set them manually. Use the governed probe harness:

```sh
# Exercise every owning-shell signal while the PG16 physical clone is running.
for signal in HUP INT TERM; do
  export CORR7_REHEARSAL_RUN_ID="corr7-clone-${signal}-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 8)"
  $HOME/recovery-rehearsal/probe-rehearsal-signal-cleanup.sh clone "$signal"
done

# Each application probe requires a fresh 24-migration clone because the actor
# script migrates it before starting the transient application.
export CORR7_EXPECTED_TREE='<FINAL_STAGED_TREE>'
export CORR7_EXPECTED_ARCHIVE_SHA256='<FINAL_RELEASE_ARCHIVE_SHA256>'
for signal in HUP INT TERM; do
  export CORR7_REHEARSAL_RUN_ID="corr7-app-${signal}-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 8)"
  $HOME/recovery-rehearsal/prepare-pg19-upgrade-rehearsal.sh
  $HOME/recovery-rehearsal/run-pg19-upgrade-rehearsal.sh
  $HOME/recovery-rehearsal/probe-rehearsal-signal-cleanup.sh app "$signal"
done
```

Required interruption results are `129` for HUP, `130` for INT, and `143` for TERM, with cleanup and both live services reported as `PASS`/`active` for clone and application probes. Each successful probe creates a unique receipt and receipt checksum under `$HOME/recovery-rehearsal/corr7-signal-evidence`; it refuses to overwrite an existing run/mode/signal receipt and writes both files at mode `0400`. Each sidecar names only the receipt basename, so after copying both files to any governed directory, verify with `(cd <governed-directory> && sha256sum -c <receipt-basename>.sha256)`. Preserve and verify those files with the final evidence archive.

Each probe sends the selected signal to the owning rehearsal shell, requires its exact conventional status, proves the transient database/application is stopped, and rechecks both live user services. After interruption testing, rebuild the disposable clone and rerun the complete normal rehearsal; interrupted state is evidence, not a reusable candidate.

## MCP OAuth actor binding

OAuth dynamic-registration metadata, including caller-supplied `client_name`, is not actor identity and must never be joined to the actor registry. When MCP is enabled, runtime requires a nonempty administrator-governed `SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS` value in canonical lowercase form:

```text
<oauth-client-uuid>=<actor-uuid>[,<oauth-client-uuid>=<actor-uuid>...]
```

Duplicate client IDs, malformed UUIDs, and a missing map fail startup. `RequireScopePlug` enforces exact `mcp` membership from the bearer plug's verified `oauth_claims["scope"]` before actor resolution. `SpruceGoose.Web.ActorPlug` then resolves only verified `oauth_claims["client_id"]` through this map to the actor's immutable `id`; OAuth user `sub`, display names, and synthetic connection assigns are ignored. Before enabling MCP in production, preserve an approved manifest containing each OAuth client ID, actor ID/name, actor active state, grants/scopes, approver, environment-file hash, and readback. Dynamic client registration alone never creates an actor binding. Keep MCP disabled during migration and Genesis bootstrap; enabling it is a separate governed restart and control step.

The PG16-only rehearsal failed at migration `20260810143000` with PostgreSQL error `42601` on `CREATE PROPERTY GRAPH`. That failure is the platform boundary and must not be worked around by skipping migrations.

## Production preflight (mandatory, not yet executed)

The production cutover is still blocked. The rehearsal scripts and evidence are not a production transaction, do not declare a freeze, do not install the reviewed live PG19 unit/release, and do not authorize a database or actor-bootstrap mutation.

As of 2026-08-11, upstream identifies PostgreSQL 19 as **Beta 2** with no final release date, while PostgreSQL 18.4 is the current supported GA major. SQL/PGQ property-graph support is a PostgreSQL 19 feature, and migration `20260810143000` requires `CREATE PROPERTY GRAPH`; therefore the reviewed migration set has no supported GA PostgreSQL target today. Production must either wait for a supported PostgreSQL 19 GA artifact and rerun this complete rehearsal against its exact package/build/unit identity, or separately redesign and review the property-graph migration. The beta2 rehearsal must not be promoted.

The verified off-host backup topology is Mama (`100.69.235.63`) → Evergreen (`ubuntu-8gb-evergreen`, `100.73.226.23`). The governed Evergreen destination is `/home/admin-papa/sprucegoose-production-backups/corr-7` at mode `0700`; a write/read/delete probe passed, and Evergreen currently has sufficient capacity relative to Mama's measured 18,529,303-byte live database. These are different hosts and different absolute paths: no bind mount or same-path assumption is permitted. Mama creates each frozen backup in a private Mama staging path, then Evergreen pulls it over the existing pinned Evergreen→Mama SSH route, verifies SHA-256 and size, and stores it under the governed destination. Capacity and a successful probe are not a backup or restore receipt: the final frozen physical backup and logical dump must still be transferred and restored into a disposable cluster before cutover authorization.

Read-only preflight receipt `corr7-live-preflight-readonly-3f0206aa.txt`, SHA-256 `24c2b6e987c0ec7c1b70fe5ba9a39f28660a17f9c4f916ef043f993111514f3d`, is preserved on Mama and Evergreen. It records active live services, actual PGDATA `/home/admin-papa/pgdata`, PostgreSQL 16.14, exactly 24 migrations, absent `actors` and `actor_grants`, loopback PostgreSQL port 5432, 18,529,303 database bytes, and 24,871,944,192 free PGDATA bytes. This is topology/prestate evidence only; it is not a deployment freeze, backup, restore, or cutover authorization.

1. Verify exact release, recovery tree, PostgreSQL source/archive, built binaries, systemd units, known-host bytes, and hashes at their execution host.
2. Verify Mama’s live services, PIDs, unit definitions, environment names, local ports, data path, binary/library paths, free disk, and backup destination.
3. Require a written deployment freeze. Reject new application mutations and stop all application/worker/outbox processes.
4. Capture:
   - current application commit/tree and release hash;
   - PostgreSQL version/settings/extensions/roles;
   - all migration versions;
   - exact public-table counts;
   - actor/actor-grant absence or expected prestate;
   - physical backup and logical dump with SHA-256, size, owner, and mode.
5. Prove rollback can restore the PostgreSQL 16 service unit, binary path, data directory, pre-actor release, environment, and database from verified artifacts.
6. Keep the PostgreSQL 16 data directory immutable after the cutover begins. Upgrade a governed copy; never use the only rollback copy as the active target.

## Production transaction outline (requires separate approval)

1. Stop and prove inactive every SpruceGoose candidate, worker, outbox, bridge mutation path, and live application process.
2. Stop PostgreSQL 16 cleanly; verify no server process remains and the data directory is consistent.
3. Create the governed PG19 target and run `pg_upgrade --check` again with the frozen source cluster.
4. Run the physical upgrade. On failure before PG19 admission, retain logs and return to the untouched PG16 rollback directory and pre-actor release.
5. Start PG19 locally with the reviewed unit. Verify version, database identity, 24 migrations, extensions, roles, and exact frozen table counts.
6. Run all nine migrations as a one-shot governed action with workers/outbox disabled. Require 33 migrations, property-graph existence, graph/relational parity, and unchanged pre-existing table counts.
7. Set `SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR=admin-papa` in the reviewed production runtime environment before the actor-aware release starts. Bootstrap `admin-papa` as the sole production Genesis human through the governed CLI/socket API. The runtime must refuse to start if the expected-Genesis setting is absent, and the locked Genesis transaction must reject any other first identity. Require exactly the seven canonical roles (`admin`, `approver`, `artifact_verifier`, `author`, `operator`, `proposer`, and `reader`) at scope `*`, each with `granted_by=genesis`. Bootstrap no additional production actor or grant without a separately approved manifest. Preserve actor/grant outputs and database readback receipts. No direct SQL bootstrap is allowed.
8. Start the reviewed actor-aware release with workers and MCP still disabled. If MCP is separately approved, register/identify the governed OAuth client, capture its immutable client ID and target actor ID in the production actor manifest, set the reviewed `SPRUCE_GOOSE_OAUTH_ACTOR_BINDINGS`, and restart; never bind by `client_name`. Require active/running/MainPID and successful real protocol probes.
9. Execute positive and negative actor authorization controls, task lifecycle controls, receipt controls, graph controls, restart persistence, and—if MCP is enabled—bound-client success plus unbound and spoofed-name refusal.
10. Enable worker/outbox processing only after the quiescent control plane passes. Verify queue health and absence of duplicate work.
11. Declare durable commit only after backups, release/environment/database identities, actor bootstrap receipts, test evidence, and rollback artifacts are recorded.

## Failure boundaries

- Before PG19 admission: restart the untouched PG16 cluster and pre-actor release only after verifying their identities.
- After PG19 starts but before migrations: stop PG19 and return to the untouched PG16 rollback directory.
- After migrations or actor bootstrap: do not improvise a downgrade. Stop the application and PG19, preserve evidence, and restore the verified prechange backup plus pre-actor release as a separately recorded rollback transaction.
- Never run reverse migrations against the only copy of production data.
- Never mark `corr-7` complete from rehearsal, tests, or code review alone.

## Cleanup

After evidence has been copied to its governed receipt location:

1. stop and verify inactive `sprucegoose-corr7-pg19.service`;
2. stop any PG19 process using the rehearsal data directory;
3. verify live services are still active/running;
4. remove only the resolved rehearsal root and private environment/launcher files;
5. do not remove `$HOME/pgdata`, the live release, live environment, or verified production backup;
6. verify ports, sockets, transient units, and processes again.

Known custody defects in artifact-receipt SQL/Ash boundaries remain separate. Successful `corr-7` recovery is not a custody or Ada promotion pass.
