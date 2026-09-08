# Dependency-Graph Queries

Three read-only commands answer reachability questions over workflow task
dependencies.

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

## Authorization

Every command first reads the named task or workflow through actor-bound Ash
authorization. Raw SQL receives only the authorized workflow UUID and cannot
traverse into another workflow. A project-scoped reader therefore sees graph
results only for that project. A grantless or out-of-scope actor is refused
before the query runs.

## How the queries work

PostgreSQL supplies the workflow-scoped vertices and edges. The traversal —
breadth-first distances, topological dynamic programming for the longest path,
tie-breaking by stable task id — runs in memory, so a dense DAG cannot make the
database enumerate every possible path.

Edge selection requires both endpoints to be tasks of the same workflow as the
edge:

```sql
SELECT edge.predecessor_id, edge.successor_id
FROM task_dependencies AS edge
JOIN workflow_tasks AS predecessor
  ON predecessor.id = edge.predecessor_id AND predecessor.workflow_id = $1::uuid
JOIN workflow_tasks AS successor
  ON successor.id = edge.successor_id   AND successor.workflow_id = $1::uuid
WHERE edge.workflow_id = $1::uuid
```

The three-way agreement is not redundant: an edge row whose `workflow_id`
disagrees with its endpoints' is excluded rather than admitted with a dangling
vertex, and `test/dependency_graph_test.exs` pins that against a corrupted-edge
fixture.

The relational tables, Ash resources, lifecycle actions, and PostgreSQL
constraints remain authoritative. These queries are observational: they never
add or remove dependencies, change task state, bypass predecessor checks, or
replace database cycle guards.

## Why this is not a property graph any more

Until 2026-09-08 the edge selection above was a SQL/PGQ `GRAPH_TABLE` query
against `sprucegoose_task_dependency_graph`, defined by migration
`20260810143000`. `CREATE PROPERTY GRAPH` exists only in an unreleased
PostgreSQL beta, so that migration made the schema **uncreatable on every
supported GA release** — no developer, CI runner, or disaster-recovery
environment could build the database at all. It was not a
production-parity problem; it was a build problem.

The property graph supplied an edge list. It supplied no traversal, no
recursion, and no ordering — all of that was already in Elixir — so the
relational query above is equivalent, and the graph semantics tests were kept
unchanged across the switch to prove it. Only the two tests that asserted on the
graph *object* were retired.

`20260908000000_drop_task_dependency_property_graph` removes the object where a
beta server created it, probing `information_schema.property_graphs` first
because on a GA server `DROP PROPERTY GRAPH` is itself a parse error. It is
deliberately irreversible: recreating the graph would reintroduce the
dependency this removes, and nothing reads the object.
