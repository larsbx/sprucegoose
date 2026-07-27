# Orchestrator

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

The application builds an operator CLI that preserves the governed task ID
schema and admits work through Ash:

```sh
mix escript.build
./orchestrator id
./orchestrator validate-id tsk-20260727T012351Z-ea5ba1b1
./orchestrator task add \
  --project pi \
  --roadmap buzz-agent-collaboration-plane \
  --workflow buzz-integration \
  --dod "Focused checks pass" \
  "Implement the next slice"
./orchestrator task list --state waiting
./orchestrator task propose tsk-...
./orchestrator task queue tsk-...
./orchestrator task ready tsk-...
./orchestrator task start tsk-...
./orchestrator task wait tsk-... "operator review"
./orchestrator task link tsk-... evidence /path/to/proof
./orchestrator task done tsk-...
./orchestrator task cancel tsk-... "superseded"
./orchestrator todo add tsk-... "Attach evidence"
./orchestrator todo list tsk-...
./orchestrator todo done tsk-... todo-...
./orchestrator inbox add "Unclassified operator note"
./orchestrator inbox list
```

Inbox captures are content-addressed and idempotent. They remain pending and
non-executable; typed project/roadmap/workflow membership and a DoD are still
required before creating a task.

Tuxedo remains the authority during migration. Ledger import is accepted only
while the durable database authority flag is `tuxedo`; it fails closed once
that flag is changed to `ash`.

The repository pins Erlang/OTP 28.3.1 and Elixir 1.19.5-otp-28 in
`.tool-versions`. Import is transactional and idempotent. Refreshes preserve
Ash-native metadata, advance optimistic-lock versions, and reconcile only
dependency edges carrying Tuxedo provenance. Import never changes authority or
writes to the source ledger:

```sh
./orchestrator ledger import /home/admin-papa/tasks/todo.txt
./orchestrator ledger parity /home/admin-papa/tasks/todo.txt
```

Parity covers stable IDs, project/roadmap/workflow membership, titles, task
types, states, recorded DoDs, raw source records, and dependency edges.
Historical tasks created before mandatory DoDs retain their missing source
value explicitly and receive a visible grandfathered placeholder in the
non-null Ash field.

Lifecycle commands expose each governed state transition explicitly. `start`
accepts only a ready task, and wait/cancel reasons are committed atomically
with their state change. Diagnosis completion requires finding, regression,
and SOP references plus completion of every subordinate TODO. Task JSON
includes those references, reasons, and ledger-import provenance.

Run the focused contract:

```sh
mix test test/cli_test.exs test/workflow_definition_test.exs test/ledger_test.exs
mix ash_postgres.generate_migrations --check
```
