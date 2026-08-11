# PostgreSQL Property-Graph Queries

SpruceGoose requires PostgreSQL 19 for its native SQL property-graph query
surface. Migration `20260810143000_add_task_dependency_property_graph.exs`
defines `sprucegoose_task_dependency_graph` over the existing
`workflow_tasks` and `task_dependencies` tables. It stores no duplicate task or
edge data.

The relational tables, Ash resources, lifecycle actions, and PostgreSQL
constraints remain authoritative. The property graph is read-only query
metadata. Existing rows are exposed without backfill, new rows appear without
projection work, and migration rollback removes only the property-graph
definition.

## Commands

```sh
sprucegoose task blockers TASK_ID
sprucegoose task impact TASK_ID
sprucegoose workflow critical-path PROJECT ROADMAP WORKFLOW
```

`task blockers` returns incomplete direct and transitive predecessors. `task
impact` returns direct and transitive successors. Both results report the
minimum edge distance and whether the relationship is direct.

`workflow critical-path` returns the longest dependency path by edge count.
When more than one path has the same length, stable task identifiers select a
deterministic result. An empty workflow returns an empty path.

Every command first reads the named task or workflow through actor-bound Ash
authorization. Raw SQL receives only the authorized workflow UUID and cannot
traverse into another workflow. A project-scoped reader therefore sees graph
results only for that project. A grantless or out-of-scope actor is refused
before the graph query runs.

PostgreSQL 19 beta 2 supports fixed-length SQL/PGQ patterns but not
variable-length patterns. SpruceGoose uses `GRAPH_TABLE` to select native graph
edges and recursive SQL to calculate reachability and longest paths. Current
tests compare graph-backed blocker results with the incumbent recursive
relational query and exercise cross-project refusal.

Graph queries are observational. They never add or remove dependencies,
change task state, bypass predecessor checks, or replace database cycle
guards.

## Rollback

Rollback executes:

```sql
DROP PROPERTY GRAPH sprucegoose_task_dependency_graph;
```

No task or dependency row changes during rollback. Remove the CLI query
commands in the same release if the migration is rolled back; otherwise they
fail explicitly because the named graph is absent.
