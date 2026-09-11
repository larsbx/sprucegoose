# Deployment domain

Status: **implemented in code; no production deployment has been executed
through it.** The native deployment control plane
(`larsbx/native-deployment-control-plane`) is subsumed here and must not be
extended; it is retired once a staging deploy and rollback have been exercised
through this domain.

## Ownership

| Component | Responsibility |
| --- | --- |
| Forgejo | Canonical source, reviews, merge authority |
| Woodpecker | Tests, builds, artifact evidence |
| `SpruceGoose.Deployment` | Release acceptance, authorization, desired deployment state, lifecycle, retention decisions, execution evidence |
| Host adapter | Bounded activation, inspection, recovery |
| Dashboard | Operator views and actions through SpruceGoose |

There is one authoritative deployment record per deployment, in
`deployments`. Host observations describe what is running; they never become
a competing policy authority.

## Resources (`SpruceGoose.Deployment.Domain`)

| Resource | Table | Mutability | Role |
| --- | --- | --- | --- |
| `Release` | `deployment_releases` | immutable | `operator` accepts |
| `Record` | `deployments` | projection; identity frozen, never deleted | `operator` creates; `operator` or `deployment_executor` projects |
| `Authorization` | `deployment_authorizations` | immutable | human `approver` issues |
| `Operation` | `deployment_operations` | projection; identity frozen, never deleted | `operator` requests; `deployment_executor` starts, completes, observes |

Scope is the release's project, resolved by SQL walk like every other
resource (`SpruceGoose.Actors.Scope`).

### Release identity

A release binds `forge_instance`, canonical `repository`, exact
`source_commit`, the Woodpecker `pipeline_number` and `pipeline_digest`, and
*typed* artifact digests: `archive`, `files`, and `image` are distinct facts
and are never conflated. `release_id` is `rel-` plus the SHA-256 of the
canonical identity, so the same release accepted twice is a refused duplicate.

Acceptance requires a succeeded `verify_artifact` derivation receipt whose
`artifact_digest` equals the archive digest, for a task in the same project.
A release cannot name bytes SpruceGoose never verified. Image and file digests
are validated in form; their custody lives outside this database and is not
claimed.

### Lifecycle

States and transitions are carried over unchanged from the native plane:

```
queued → building → staged → deploying → verifying → ready
                  ↘ cancelled          ↘ failed ↘ rolling_back → rolled_back
```

`ready`, `failed`, `rolled_back`, `cancelled` are terminal: the rollout has
finished. Rollback is a new operation on a finished deployment, not a
continuation of it. Production deployments carry `requires_routing: true`.

### Certified stream

Every mutation appends one event on `deployment:<deployment_id>` in the same
transaction as the row update, under a per-deployment advisory lock. Each
payload names the identity of the event before it in `previous`, so the
stream is a hash chain inside the certified ledger. `Projection.reduce/1`
refuses at the first broken link, illegal transition, or out-of-order
operation phase, and `deployment show` reports parity between the row and the
replay.

Events distinguish what was requested from what happened:

| Event | Meaning |
| --- | --- |
| `DeploymentCreated`, `DeploymentTransitioned`, `DeploymentHealthObserved`, `DeploymentCancellationRequested`, `DeploymentRollbackRequested` | lifecycle bookkeeping |
| `DeploymentOperationRequested` | an authorization was spent; carries approver, reference, and evidence |
| `DeploymentOperationStarted` | an executor committed to acting, *before* acting |
| `DeploymentOperationCompleted` | outcome, with `source` = `executor` (adapter receipt) or `observation` (host inspection) |
| `DeploymentOperationObserved` | what host inspection reported |

A deploy is not "executed" until its completion is recorded.

## Authorization

Effects are `execute_deploy`, `execute_rollback`, `execute_reclaim`. Each
needs an `Authorization`: issued by a **human** holding `approver` over the
project, bound to one deployment and one action (a rollback names its
target), carrying an approval reference, expiring within an hour. The row is
immutable.

`Deployment.request/2` spends it. In one transaction it re-validates every
precondition against live state, inserts the `Operation` (unique on
`authorization_id`: the single-use invariant is a database fact), appends the
request event, advances the lifecycle, and enqueues the executor job. A
refused request rolls everything back and spends nothing. A spent
authorization is reported as `:authorization_already_spent`.

Preconditions:

- **deploy**: state `staged`; where routing is required, fresh routing
  evidence that `Routing.evaluate/3` accepts — omitted evidence is
  `:routing_evidence_required`, never a pass; supplied evidence is evaluated
  even where not required.
- **rollback**: state in `ready | failed | deploying | verifying`; target is a
  distinct, `ready` deployment of a different release in the same project and
  environment.
- **reclaim**: environment `preview`, not already reclaimed, judged against the
  live preview cohort by `Retention.assert_reclaimable/4` with verified
  recovery evidence supplied by the caller.

## Execution

`SpruceGoose.Deployment.Executor` (Oban queue `deployments`) runs as the
actor named by `SPRUCE_GOOSE_DEPLOYMENT_EXECUTOR_ACTOR`, which must hold
`deployment_executor`, through the adapter in `:deployment_host_adapter`.

1. `requested` → record `started`, commit, then call `adapter.execute/1`
   with a timeout (`:deployment_operation_timeout_ms`).
2. Adapter receipt → `completed` with `source: executor`.
3. Timeout or crash → `adapter.observe/1`; record the observation; complete
   from it when the host confirms an outcome, otherwise return an error so
   Oban retries the reconciliation. The effect is never re-executed.
4. A retry finding `started` reconciles; finding `completed` discards.

`deployment reconcile OPERATION_ID` re-queues an operation whose job was
exhausted. Completion advances the lifecycle: deploy → `verifying` (then
`observe-health`), rollback → `rolled_back`, failure → `failed`, reclaim →
`reclaimed_at`.

### Host adapters

`SpruceGoose.Deployment.HostAdapter` is the behaviour: `execute/1` and
`observe/1` over an identity-only request. `HostAdapter.Scripted` drives the
existing `scripts/activate-sprucegoose-release`: it derives every path from
static configuration and the release's governed receipt, passes the operation
ID as the script's `--task` and confirmation token, and observes by reading
the activation record and failed-release marker the script itself leaves
behind. The script's "activation record already exists" check is the host-side
duplicate detection.

The live host has not run this adapter. Before the standalone control plane
is retired, exercise a staging deploy and rollback through it.

## CLI

```
sprucegoose deployment release-accept PROJECT --forge-instance ID --repository OWNER/REPO \
  --commit OID --pipeline-number N --pipeline-digest SHA256 --archive sha256:HEX
sprucegoose deployment create RELEASE_ID staging
sprucegoose deployment stage DEPLOYMENT_ID
sprucegoose deployment authorize DEPLOYMENT_ID --action execute_deploy --reference REF --as lars
sprucegoose deployment request AUTHORIZATION_ID [--routing JSON] [--recovery-verified]
sprucegoose deployment observe-health DEPLOYMENT_ID healthy|unhealthy [DETAIL]
sprucegoose deployment show|events DEPLOYMENT_ID
sprucegoose deployment list [--project KEY]
```

## Migration from the native plane

Contracts carried over: release identity (widened with forge, pipeline, and
typed digests), lifecycle states and transitions, routing preconditions,
retention rules, and the read projection. The native `deploy_executed` event
is replaced by the requested/started/completed/observed set above. Routing
evidence is now required where the deployment requires it rather than
optional. Grants are rows approved by a human rather than HMAC-signed
in-process structs: the database, not a signature, is the authority.

Historical native ledger rows are not imported by this change; they keep
their meaning under the unchanged state vocabulary and can be imported as a
grandfathered baseline in a separate governed transaction.
