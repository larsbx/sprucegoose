# Lifecycles

SpruceGoose has two declared state machines: the task lifecycle and the
deployment lifecycle. Both are declarations on `SpruceGoose.Lifecycle`
(`lib/spruce_goose/lifecycle.ex`), which verifies each declaration when it
compiles and exposes one query API over it. `test/lifecycle_test.exs` decides
the remaining properties by enumerating the whole relation: every state is
reachable from the initial state, every state can reach a terminal state, the
relation is irreflexive and closed, and every sink is terminal.

The tables below are rendered from the modules by
`SpruceGoose.Lifecycle.to_markdown/1` and pinned by the same test. To change a
lifecycle, change the module; the test will tell you to regenerate this file:

```
mix run --no-start -e "IO.puts(SpruceGoose.Lifecycle.to_markdown(SpruceGoose.Workflows.Lifecycle))"
```

The relation is the *shape* of a lifecycle. Preconditions that depend on data
belong to the resource action that performs the edge and are listed under
each table.

## Task

<!-- lifecycle:SpruceGoose.Workflows.Lifecycle -->
`SpruceGoose.Workflows.Lifecycle`, version 1. Initial state `inbox`; terminal states `completed`, `cancelled`.

| from | to |
| --- | --- |
| `inbox` | `proposed`, `cancelled` |
| `proposed` | `queued`, `cancelled` |
| `queued` | `ready`, `blocked`, `cancelled` |
| `ready` | `in_progress`, `blocked`, `cancelled` |
| `in_progress` | `waiting`, `blocked`, `completed`, `failed`, `cancelled` |
| `waiting` | `ready`, `in_progress`, `blocked`, `cancelled` |
| `blocked` | `ready`, `cancelled` |
| `completed` | — |
| `failed` | `queued`, `cancelled` |
| `cancelled` | — |
<!-- /lifecycle -->

`failed` is recoverable: it re-enters `queued`. `completed` and `cancelled`
are absorbing. `waiting` may resume straight into `in_progress`, through the
same SOP gate as a fresh start; `blocked` must pass back through `ready`.

Guards on top of the relation, all in `SpruceGoose.Workflows.Task`, each
enforced by the Ash action and, where marked, by a PostgreSQL trigger as well:

| Edge | Guard | Trigger |
| --- | --- | --- |
| `* → in_progress` | Systemwide SOP acknowledgment current (`SopGate.verify/1`), on start and on resumption from `waiting` alike | — |
| `* → in_progress` | every predecessor `completed` | `workflow_tasks_start_predecessor_guard` |
| `* → ready` | every `artifact_requirements` entry has a verified receipt | `workflow_tasks_artifact_receipt_guard` |
| `* → completed` | every TODO completed; diagnosis tasks carry finding, regression and SOP references | `workflow_tasks_completion_todo_guard` |
| `* → waiting`, `* → cancelled` | a non-blank reason | — |
| any, when on a board | a column exists for the target state | `workflow_tasks_board_membership` |

`Task.:move` also admits the identity (a re-rank within a column), so it
enforces the relation together with the identity; `Task.:transition` enforces
the relation alone. Membership of `workflow_tasks.state` in the state set is a
`CHECK` constraint generated from the module. The task projector
(`SpruceGoose.Kernel.TaskProjector`) enforces the same relation, plus the
identity, when it replays certified history.

## Deployment

<!-- lifecycle:SpruceGoose.Deployment.Lifecycle -->
`SpruceGoose.Deployment.Lifecycle`, version 1. Initial state `queued`; terminal states `ready`, `failed`, `rolled_back`, `cancelled`.

| from | to |
| --- | --- |
| `queued` | `building`, `cancelled` |
| `building` | `staged`, `failed`, `cancelled` |
| `staged` | `deploying`, `cancelled` |
| `deploying` | `verifying`, `failed`, `rolling_back` |
| `verifying` | `ready`, `failed`, `rolling_back` |
| `ready` | `rolling_back` |
| `failed` | `rolling_back` |
| `rolling_back` | `rolled_back`, `failed` |
| `rolled_back` | — |
| `cancelled` | — |
<!-- /lifecycle -->

Terminal means *finished*, not *absorbing*: `ready` and `failed` may still roll
back, because rollback is a new operation on a finished deployment. `failed ⇄
rolling_back` is a cycle by design; each step is an operator-initiated
operation. `terminal_at` is set on the first entry into a terminal state and
is never reset.

`deployments.state` is written only by the `Deployment.Record.:transition`
action, which checks the relation; `Deployment.transition/2` checks it once
more before appending the `DeploymentTransitioned` event so an illegal edge
leaves no event behind, and `Deployment.Projection` checks every replayed
event. Membership of `deployments.state` in the state set is the
`deployment_shape` `CHECK` constraint in the deployment domain migration.
