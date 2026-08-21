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

## Legible repository blueprints and views

The normative, operative, evidentiary, and projection boundaries are defined
in [`docs/authority-planes.md`](docs/authority-planes.md). The current kernel
conformance gaps and dependency-ordered remediation are recorded in the
[`v0.2 audit`](docs/audits/2026-08-21-abstract-deontic-kernel-v0.2.md) and
[`remediation plan`](docs/abstract-kernel-remediation-plan.md).

Git is the reviewed specification surface; Ash/PostgreSQL remains the sole
live authority. An approver can register an immutable blueprint source identity
or atomically apply its roadmap and workflow definitions. The record binds the
project to a repository slug, commit, tree, relative path, manifest digest, and
schema version. It has no update or destroy action. It may define reusable
TaskDefinitions, but never imports TaskInstances, lifecycle state, actors,
grants, approvals, shell commands, or deployments.

```sh
./sprucegoose blueprint register my-project root/my-project \
  <40-hex-commit> .sprucegoose/project.yaml \
  --as release-approver

./sprucegoose blueprint apply my-project root/my-project \
  <40-hex-commit> .sprucegoose/project.yaml \
  --as release-approver

./sprucegoose task instantiate \
  --project my-project --roadmap delivery --workflow release-v1 \
  --blueprint bpr-... --definition test --priority 1 --as operator

./sprucegoose project view my-project --as operator
```

`project view` returns the same authorized project hierarchy in three read-only
forms: structured data, Markdown, and Graphviz DOT. The view includes stable
project, roadmap, workflow, task, and blueprint identifiers. Generated text is
explicitly labeled as a projection and is never accepted as mutation input.
Blueprint registration independently reads the commit, tree, and path bytes
through Forgejo. SpruceGoose derives the manifest digest; callers cannot supply
the tree or digest recorded by the Ash action. Apply validates the whole
versioned YAML package before writing, then creates or revises its project-scoped
roadmaps and workflows in one database transaction. Any invalid definition or
write failure leaves both hierarchy and revision receipt unchanged.
Instantiation re-verifies the referenced commit/path bytes and copies the
typed runner, input, title, Definition of Done, dependencies, and artifact
requirements from that exact revision; it does not trust a mutable workflow
row. `task add` and `inbox promote` are retired operator paths. Use `inbox add`
for a non-authoritative work request, then commit a TaskDefinition and use
`task instantiate`. Pre-cutover tasks retain null source bindings as the
explicit grandfathered epoch rather than receiving fabricated repository
provenance.
The production verifier reads a repository-read-only token from the owner-only
path configured by `SPRUCE_GOOSE_FORGEJO_READ_TOKEN_FILE`; it does not use the
ICM publication credential.

```yaml
schema_version: 1
project: my-project
roadmaps:
  - key: delivery
    name: Delivery
    workflows:
      - id: release-v1
        name: Release v1
        definition:
          schema_version: 1
          tasks:
            - id: test
              kind: oban
              title: Run tests
              definition_of_done: The governed test suite passes
              depends_on: []
              artifact_requirements: [test-report]
              input: {}
```

```sh
mix escript.build
./sprucegoose-direct id
./sprucegoose-direct validate-id tsk-20260727T012351Z-ea5ba1b1

# One-time, on an empty registry: genesis creates the first human as a
# full-scope actor. Every later actor needs an admin to create it.
./sprucegoose actor add lars --kind human --description operator
./sprucegoose actor add openclaw --kind agent --as lars
./sprucegoose grant add openclaw --role operator --scope project:my-project --as lars
./sprucegoose whoami --as openclaw

./sprucegoose blueprint apply my-project root/my-project \
  <40-hex-commit> .sprucegoose/project.yaml --as release-approver
./sprucegoose task instantiate \
  --project my-project \
  --roadmap delivery \
  --workflow release-v1 \
  --blueprint bpr-... \
  --definition test \
  --priority 2 \
  --as openclaw
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

PostgreSQL 19 exposes task dependencies as the read-only property graph
`sprucegoose_task_dependency_graph`. The three graph commands authorize the
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
