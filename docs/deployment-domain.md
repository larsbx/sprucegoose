# Deployment domain integration

## Ownership and implementation boundary

Forgejo owns source, review, and merge authority. Woodpecker owns canonical test,
build, and artifact evidence. SpruceGoose will own deployment acceptance,
authorization, desired state, lifecycle, retention decisions, and execution
evidence in its existing persistence layer. The dashboard presents those records
and invokes governed actions. A separately runnable host adapter performs bounded
Podman/systemd operations and recovery when SpruceGoose is unavailable.

This change imports **pure contracts**, not an active Ash deployment domain.
`SpruceGoose.Deployment.*` has no Repo, supervisor child, CLI mutation, worker,
network client, or host command. It is deliberately not connected to the existing
outbox. It does not consume grants, accept releases, migrate a ledger, or deploy.

| Contract | Imported behavior and corrections |
| --- | --- |
| `Contract`, `StateMachine` | Native v1 lifecycle vocabulary and transition table; unknown transitions refuse |
| `Release` | Original source commit and OCI image identity for legacy compatibility; this is not a Forgejo/Woodpecker acceptance record |
| `BuildManifest` | Original deterministic v1 encoding and manifest digest; commands are inert data |
| `Artifact` | Distinct archive, OCI image, and native v1 file-collection identities; verification requires the expected kind; valid collections preserve the native encoding |
| `Rollback` | Distinct, valid, previously ready release in the same project/environment; no immediate rolled-back completion |
| `Routing` | Required routing cannot be omitted; fresh DNS, certificate, upstream, and recovery evidence; only an explicit authoritative `:unrouted` policy skips the routing gate |
| `Preview` | Preview-only TTL/grace and minimum retention; unknown pin/reference status retains; ambiguous cohorts refuse; other environments cannot fill preview retention slots |
| `Operation` | Requested, started, unknown after timeout, and observed-completed are distinct; bound, fresh completion receipts; identical receipt replay is idempotent |

The operation model currently covers successful deploy/rollback completion and
unknown outcomes. It is not a durable deduplication service or a complete failure
and retry policy. Its map inputs are not authenticated evidence. A future adapter
must authenticate receipts before passing them to this contract. Replaying an
identical already accepted receipt does not reapply the freshness gate.

## Source provenance and canonical reconciliation

The import was prepared against accessible GitHub mirror snapshots:

| Repository | Inspected commit | Relevant boundary |
| --- | --- | --- |
| [sprucegoose](https://github.com/larsbx/sprucegoose/tree/53bbba1aad1914091a1ef49b35484aa1e5a530f8) | `53bbba1aad1914091a1ef49b35484aa1e5a530f8` | Ash authority, transactional outbox, artifact store, runtime observation port |
| [native-deployment-control-plane](https://github.com/larsbx/native-deployment-control-plane/tree/4341cbf2005a3bd4d4b93e365418ec6097d7dca4) | `4341cbf2005a3bd4d4b93e365418ec6097d7dca4` | Imported contracts and tests from `lib/native_deployment` and `test/native_deployment` |
| [spruce](https://github.com/larsbx/spruce/tree/10b947988aa112dffda7c1d9b9eb67350bf9185d) | `10b947988aa112dffda7c1d9b9eb67350bf9185d` | Agent/tool execution patterns; task authority remains in SpruceGoose |
| [agent-runtime-platform](https://github.com/larsbx/agent-runtime-platform/tree/d2ea4caa6f3da76dff093aa9bce4a1ded1cbb0b5) | `d2ea4caa6f3da76dff093aa9bce4a1ded1cbb0b5` | Rootless runtime adapter patterns; standalone extraction is a prerequisite to adoption |
| [accountabot_dashboard](https://github.com/larsbx/accountabot_dashboard/tree/aadc1b5b80f8b0c7d186da1811ed7331e08f1da3) | `aadc1b5b80f8b0c7d186da1811ed7331e08f1da3` | Operator UI reads and governed actions |

No canonical Forgejo checkout, Woodpecker instance, or live host was available
for inspection during this import. No canonical task ID or canonical head is
claimed. Mirror commits are evidence references, not merge authority.

Before a canonical PR, record the Forgejo repository URL, default branch, head
and tree; compare its ancestry and diff against the SpruceGoose mirror base
above. Identify equivalent canonical versions of the native contracts. Preserve
canonical-only changes and port this commit onto a branch from the canonical
head. Do not overwrite either main branch or infer equivalence from filenames.
Use an existing governed task admitted through the current blueprint workflow.
Record the original import commit and resulting canonical commit in the PR.

Prerequisites carried from [the reconciliation handoff](sprucegoose-reconciliation-handoff.md):

- Verify canonical inclusion of the PR #6 test-gate fix: blank database connection
  variables normalize to unset; invalid ports refuse; trust and password-backed
  test databases both run; ordinary and separate-session failures fail the gate
  and clean up only the disposable CI database. Preserve its regression tests.
- Verify canonical inclusion of `scripts/audit-dependencies` and the accepted
  dependency update. Executable runbook/CI audit gates call the wrapper, including
  the canonical deployment runbook. Bare `mix hex.audit` is only an internal
  wrapper implementation or explanatory text, never the acceptance gate.
- Verify PR #7 automation equivalents on Forgejo/Woodpecker. A green GitHub check
  alone neither reconciles source nor proves the canonical gate passed.

## Next slice: authorization, persistence, and historical evidence

Add Ash resources/actions under SpruceGoose's established authority and Repo.
Native grant maps and HMAC grant issuance must not become a second authorizer.
The current derivation permit only permits test/build/verify operations; it does
not authorize deployment. Do not expand its executor to run irreversible host
effects inside a database transaction.

The admission transaction must lock/revalidate deployment state and scope,
validate the exact rollback target where applicable, consume the bound
authorization, insert an immutable operation request with a stable ID, append
the certified request event, and insert the outbox work together. Bind the task,
actor, authority roots/revocation epoch, deployment revision, target host and
environment, release identity, rollback target, routing policy, and evidence
identities. Same ID plus different content must refuse. Invalid preconditions or
an append/enqueue failure must leave neither a spent grant nor partial work.

Preserve original deployment IDs, event IDs/order/timestamps, raw payload bytes,
artifact/manifest bytes and digests, and grant-spend records in an explicit
legacy import namespace. Inventory counts and ordered digests before migration.
Quarantine malformed or unresolvable records with their original bytes; never
invent repository, pipeline, approval, or completion evidence. Existing
`deploy_executed`, `rollback_executed`, and `reclaim_executed` names remain in
historical bytes but classify as request evidence only. A legacy `rolled_back`
state alone is also insufficient to assert observed host completion.

Acceptance gates for that slice:

- Concurrent acceptance of the same request creates one operation/outbox item;
  retries return the same accepted identity; conflicting content refuses.
- Revoked, expired, wrong-action, wrong-resource, wrong-environment, or stale
  authorization refuses with zero committed side effects.
- Inject failure at every transaction boundary, including certified append and
  enqueue; prove grant consumption and request/outbox atomicity using independent
  database sessions, not only shared SQL sandbox transactions.
- Import into a disposable database twice; prove byte/digest/count/ordering
  parity, idempotency, conflict refusal, direct update/delete refusal, and replay
  equivalence. Tampered/truncated evidence must refuse. Exercise recovery before
  any authority cutover. The standalone plane remains retained until then.

## Next slice: Woodpecker evidence and hooks

An accepted release must resolve to the configured canonical Forgejo instance,
repository, immutable commit/tree, reviewed ref, Woodpecker instance, pipeline
ID and attempt, pipeline/config digest, successful required gates, and typed
artifact plus verification evidence. Explicitly convert a raw archive receipt's
64-hex SHA to the typed archive representation at that boundary. Never reinterpret
a native file-collection hash or OCI image digest as an archive hash.

Forgejo events trigger Woodpecker checks. Successful canonical build evidence
may request release acceptance from SpruceGoose; it cannot authorize activation.
Any webhook adapter must verify the configured sender, reject replay/conflicting
event content, and retrieve immutable evidence before admission. Local hooks
provide feedback; they are not authority or CI attestations. Use
`scripts/audit-dependencies` and the shared check script on canonical CI.

Acceptance gates: reject wrong forge/repository/commit/tree/ref, failed or
incomplete gates, stale/replayed conflicting pipeline evidence, missing artifact
bytes, wrong digest type, altered bytes, and unverified sender. Accept repeated
byte-identical evidence once. PR code runs only on isolated disposable runners
without host deployment sockets or secrets; inspect canonical runner configuration
before enabling PR execution on the local backend. Do not assume the existing
push-only `.woodpecker.yml` already enforces those isolation requirements.

## Next slice: adapter and independent recovery

Outbox delivery is at-least-once and may repeat after external success. The host
adapter needs a durable journal keyed by the complete operation identity, bounded
allowlisted operations and targets, authenticated requests/receipts, and inspection
of the actual host. Receipt persistence and transport retries must not repeat the
host effect. A timeout leaves the outcome unknown; inspect before retrying.
Observed process completion and service health remain distinct deployment facts.

The adapter's journal and observations are execution evidence, not competing
desired-state authority. Offline recovery must use a previously authorized,
bounded recovery plan with retained artifacts and a separately available operator
entry point. It cannot depend on calling the unavailable SpruceGoose instance to
restart SpruceGoose. Recovery actions require later evidence reconciliation.

Acceptance gates: simulate crashes before start, after host effect, and before
receipt acknowledgment; duplicate delivery and conflicting IDs; stale/mismatched
observations; unreachable host; health-check failure; recovery with SpruceGoose
down; staging deploy and rollback to verified retained artifacts. Reclamation
requires a fresh authoritative cohort and recovery evidence at execution. No
standalone control-plane retirement or live activation precedes these gates.

## Local validation and review

`scripts/test-deployment-contracts` runs the pure ExUnit suite without Mix
dependencies, application startup, network, or a database. The same test files
are automatically included by `mix test`, including the existing Woodpecker
shared check path. The contract tests do not establish end-to-end persistence,
host execution, or authenticated release admission.

Canonical review must run `scripts/check-local`, the contract tests, formatter,
warnings-as-errors compilation, and `scripts/ci-governed-release --check` against
both trust and password-backed disposable databases. Merge on Forgejo only after
those gates pass on the exact canonical candidate. Mirror downstream afterward.
Keep activation and live schema changes out of this reconciliation PR.
