# SpruceGoose

This app is the proving ground for the authoritative Postgres/Ash orchestration
DSL. Ash resources and actions model:

`Project → Roadmap → Workflow → Task → TODO`

- Every level has stable identity and explicit parentage.
- Tasks own DoD, lifecycle, runner, inputs, dependencies, and optimistic
  versioning.
- TODOs are subordinate checklist state, never task or execution authority.
- Versioned definitions validate complete DAGs and produce deterministic
  topological order.
- Ash actions expose guarded task transitions; native runners perform effects.

Allowed task kinds map to Oban, TaskFlow, or OpenClaw. Those runtimes remain
effect executors; Postgres/Ash owns orchestration state and invariants.

The production operator CLI is a thin client for a persistent OTP service over
`$XDG_RUNTIME_DIR/sprucegoose/cli.sock`. The socket directory is mode `0700`,
each request runs in its own supervised task, and every request has a bounded
deadline. One stalled request therefore cannot head-of-line block another.
There is no cold-start fallback: an unavailable service fails fast so an
operator never mistakes a second application boot for a successful command.

Build the release and install the thin client:

```sh
MIX_ENV=prod mix release --overwrite
install -m 0755 scripts/sprucegoose-client.py ./sprucegoose
```

The retained `sprucegoose-direct` escript is break-glass recovery only. Normal
automation uses `./sprucegoose`, which preserves the governed task ID schema
and admits work through the running Ash application:

Rollback is explicit: stop and disable `sprucegoose.service`, then install the
retained `sprucegoose-direct` artifact back to `./sprucegoose`. Direct mode
requires the production database and signing environment and restores the old
cold-start latency; it is recovery, not an automatic fallback.

The live authority moved from evergreen to mama on 2026-08-02. See
[`ops/mama-authority/README.md`](ops/mama-authority/README.md) for the
versioned bridge, backup, restart, and rollback procedure and
[`ops/mama-authority/MIGRATION_PROGRESS.md`](ops/mama-authority/MIGRATION_PROGRESS.md)
for the cutover evidence.

Every command acts as a named actor and is authorized against that actor's
scoped grants. A store with an empty actor registry bootstraps its first
operator through genesis; after that, `--as NAME` (or `SPRUCE_GOOSE_ACTOR`)
identifies the caller and an unnamed request is refused. See
[`docs/authorization.md`](docs/authorization.md) for the model, the roles, and
an honest account of what a declared actor does and does not prove.

Changing what an entity *says* — a roadmap's name, a workflow's DAG, a task's
Definition of Done — goes through `revise`: a TOML sparse patch proposed once
and applied only after an explicit sign-off bound to the digest of the reviewed
bytes. See [`docs/revisions.md`](docs/revisions.md).

```sh
mix escript.build
./sprucegoose id
./sprucegoose validate-id tsk-20260727T012351Z-ea5ba1b1

# One-time, on an empty registry: genesis creates the first human as a
# full-scope actor. Every later actor needs an admin to create it.
./sprucegoose actor add lars --kind human --description operator
./sprucegoose actor add openclaw --kind agent --as lars
./sprucegoose grant add openclaw --role operator --scope project:my-project --as lars
./sprucegoose whoami --as openclaw

./sprucegoose project add my-project "My project"
./sprucegoose roadmap add my-project delivery "Delivery roadmap"
./sprucegoose workflow add \
  --project my-project \
  --roadmap delivery \
  --definition '{"schema_version":1,"tasks":[{"id":"verify","kind":"oban","depends_on":["build"]},{"id":"build","kind":"oban"}]}' \
  release "Release workflow"
./sprucegoose task add \
  --project pi \
  --roadmap buzz-agent-collaboration-plane \
  --workflow buzz-integration \
  --priority 2 \
  --artifact prototype \
  --dod "Focused checks pass" \
  --sop "/home/admin-papa/.openclaw/vaults/openclaw-system/10-sop/Systemwide SOP.md" \
  "Implement the next slice"
./sprucegoose task artifact-receipt tsk-... \
  prototype /absolute/path/to/prototype telegram:message:6680 --as artifact-verifier
./sprucegoose task list --state waiting
./sprucegoose task blockers tsk-...
./sprucegoose task impact tsk-...
./sprucegoose workflow critical-path my-project delivery release
./sprucegoose task propose tsk-...
./sprucegoose task queue tsk-...
./sprucegoose task ready tsk-...
./sprucegoose task start tsk-...
./sprucegoose task wait tsk-... "operator review"
./sprucegoose task link tsk-... evidence /path/to/proof
./sprucegoose task acknowledge-sop tsk-... \
  "/home/admin-papa/.openclaw/vaults/openclaw-system/10-sop/Systemwide SOP.md"
./sprucegoose task done tsk-...
./sprucegoose task cancel tsk-... "superseded"
./sprucegoose todo add tsk-... "Attach evidence"
./sprucegoose todo list tsk-...
./sprucegoose todo done tsk-... todo-...
./sprucegoose inbox add "Unclassified operator note"
./sprucegoose inbox list

# Governed revision: propose, review, then sign off on the exact bytes.
./sprucegoose revise propose --file /abs/path/rev.toml --as openclaw
./sprucegoose revise show rev-... --as lars
./sprucegoose revise approve rev-... --task tsk-... --digest <sha256> --as lars
```

The PostgreSQL 19 staging/rehearsal line exposes task dependencies as the
read-only property graph `sprucegoose_task_dependency_graph`; production remains
on PostgreSQL 16.14 at migration 24. The three graph commands authorize the
named task or workflow through Ash before executing workflow-scoped SQL. The
relational task and dependency tables remain authoritative; graph queries do
not transition tasks or change edges. See
[`docs/property-graph-queries.md`](docs/property-graph-queries.md).

For the integrated nine-migration architecture, actor and custody boundaries,
snapshot rehearsal workflow, production gate, and exported DAG visuals, see
[`docs/system-additions.md`](docs/system-additions.md). The visual exports are
versioned under [`docs/diagrams/`](docs/diagrams/).

Inbox captures are content-addressed and idempotent. They remain pending and
non-executable; typed project/roadmap/workflow membership and a DoD are still
required before creating a task.

SpruceGoose/Ash has been authoritative since
`2026-07-27 12:00:27.831082 UTC`. The database cutover is irreversible:
PostgreSQL rejects authority reversal and cutover-timestamp mutation. Tuxedo,
`taskctl`, and the legacy ledger are retired, read-only recovery evidence.
Ledger import remains compiled only for explicit offline recovery rehearsal
against a separately named recovery database. It requires global `admin`, a
configured intake root, `LEDGER_RECOVERY_MODE=true`, a matching
`LEDGER_RECOVERY_DATABASE`, and legacy authority mode in that isolated store.
It is rejected on the live authority database and is not an operator workflow.

The repository pins Erlang/OTP 28.3.1 and Elixir 1.19.5-otp-28 in
`.tool-versions`. Import is transactional and idempotent. Refreshes preserve
Ash-native metadata, advance optimistic-lock versions, and reconcile only
dependency edges carrying Tuxedo provenance. Import never changes authority or
writes to the source ledger:

Historical parity evidence may be inspected by a global admin after the
protected ledger is copied into the configured intake root. Never edit or
re-import the authoritative historical ledger after cutover.

Parity covers stable IDs, project/roadmap/workflow membership, titles, task
types, states, recorded DoDs, raw source records, and dependency edges.
Historical tasks created before mandatory DoDs retain their missing source
value explicitly and receive a visible grandfathered placeholder in the
non-null Ash field.

Lifecycle commands expose each governed state transition explicitly. Every
public Ash transition into `in_progress`, including `start`, accepts only a
ready task with a current Systemwide SOP acknowledgment. Admission reads the
configured SOP and stores its stable identifier, path, SHA-256 digest, and
acknowledgment time; transition re-reads it and rejects a stale digest.
`SYSTEMWIDE_SOP_PATH` selects the deployment path without changing the stable
`systemwide-sop` evidence identifier.
`task acknowledge-sop` refreshes a nonterminal task after an SOP change.
Ordinary Ash callers cannot set acknowledgment fields or choose the exemption;
only the retired SQL import path can create explicitly grandfathered records.
Wait/cancel reasons
are committed atomically with their state change. Diagnosis completion
requires finding, regression, and SOP references plus completion of every
subordinate TODO. Task JSON includes those references, reasons,
SOP acknowledgment, and ledger-import provenance.

Kanban administration uses the same canonical CLI:

```sh
./sprucegoose board add PROJECT ROADMAP WORKFLOW KEY "Board name"
./sprucegoose board list PROJECT ROADMAP WORKFLOW
./sprucegoose column add BOARD_ID KEY POSITION STATE "Column name"
./sprucegoose column list BOARD_ID
./sprucegoose task move TASK_ID BOARD_ID COLUMN_ID RANK
./sprucegoose task metadata TASK_ID '{"priority":2,"labels":["audit"]}'
./sprucegoose filter add BOARD_ID NAME '{"assignee":"jimbo"}'
./sprucegoose filter list BOARD_ID
./sprucegoose filter apply FILTER_ID
```

Moves are one governed Ash transaction: board, column, workflow, lifecycle
state, rank, and optimistic revisions must agree. TODO admission is serialized
with completion and is rejected after completion or cancellation.

Run the focused contract:

```sh
mix test test/cli/socket_plug_test.exs test/cli/socket_service_test.exs
mix test test/cli_test.exs test/workflow_definition_test.exs test/ledger_test.exs
mix ash_postgres.generate_migrations --check
```

The service boundary was reviewed against Twelve-Factor `main` commit
`655b020ac25eac8f912ccc845094ec16cdf6b30b`: dependencies and configuration
remain explicit, PostgreSQL is a backing service, build/release/run are
separate, requests are concurrent and disposable, logs remain event streams,
and administrative commands use the same running release. The Unix socket is
a stronger local security boundary than application port binding and is an
intentional host-level extension beyond the application factors.
