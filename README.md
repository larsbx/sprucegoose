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

Tuxedo remains a temporary migration input until ledger import, parity,
rollback, and cutover checks pass. It is then retired rather than retained as
a second writable task system.

The repository pins Erlang/OTP 28.3.1 and Elixir 1.19.5-otp-28 in
`.tool-versions`. Import is transactional and idempotent. It does not change
task authority or write to the source ledger:

```sh
./orchestrator ledger import /home/admin-papa/tasks/todo.txt
./orchestrator ledger parity /home/admin-papa/tasks/todo.txt
```

Parity covers stable IDs, project/roadmap/workflow membership, titles, task
types, states, recorded DoDs, raw source records, and dependency edges.
Historical tasks created before mandatory DoDs retain their missing source
value explicitly and receive a visible grandfathered placeholder in the
non-null Ash field.

Run the focused contract:

```sh
mix test test/cli_test.exs test/workflow_definition_test.exs test/ledger_test.exs
mix ash_postgres.generate_migrations --check
```
