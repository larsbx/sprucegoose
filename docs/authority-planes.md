# SpruceGoose authority planes

SpruceGoose classifies propositions before selecting an authority. No storage
product gains authority merely because the system stores data in it.

> Content-addressed artifacts define what may happen. The ledger records what
> did happen.
> Evidence proves what was observed. Projections explain the result.

## Authority map

| Plane | Canonical content | Required properties |
| --- | --- | --- |
| Constitutive | Kernel code, schemas, migrations, policies, ontologies, agent charters, capabilities, oracle definitions, Project/Roadmap/Workflow/TaskDefinition manifests, deployment declarations | Reviewed, content-addressed artifacts that are independently reconstructible |
| Historical | Requests, licensed transitions, commitments, executions, memberships, orders, jobs, workflow state, and terminal outcomes | Append-only certified event ledger with transactional identities and ordering |
| Evidentiary | Runtime artifacts, observations, witnesses, receipts, logs admitted as evidence, and oracle outputs | Content-addressed object custody; digest and provenance committed by a certified historical event |
| Derived | Current rows, balances, dashboards, queues, reports, Markdown, JSON, DOT, vector indexes, and search indexes | Rebuildable from authoritative artifacts and events; never accepted as authority input |

The constitutive plane cannot assert that an event happened. The historical
plane cannot create a rule merely by storing a row. The evidentiary plane
cannot license an effect merely because bytes exist. A projection cannot
authorize any mutation.

## Proposition dispatch

The kernel asks what class of proposition is being established before it asks
where any bytes happen to live.

| Proposition | Permitted authority |
| --- | --- |
| Is this operation forbidden or required? | Versioned deontic artifacts |
| Did operation X occur? | Certified event ledger |
| Is the current balance 72? | Projection derived from ledger events |
| Is X a subtype of Y? | Versioned semantic or ontology artifacts |
| Does this program type-check? | Versioned schema, syntax, and toolchain artifacts |

Database insertion cannot establish normative truth. Artifact publication
cannot establish historical truth. Evidence bytes become historically
admitted only when a certified ledger event binds their content identifiers.

## Kernel ports

The kernel depends on capabilities, not Git or PostgreSQL:

```text
ArtifactStore.get(ContentID) -> Artifact
ArtifactStore.verify(ContentID) -> Verification

EventLedger.append(CertifiedEvent) -> EventIdentity
EventLedger.read(Query) -> OrderedEvents
EventLedger.verify(EventIdentity) -> Verification
```

Normative, semantic, and schema stores may share one physical adapter, but
remain distinct authority roles. Git and Forgejo are the first ArtifactStore
adapters. PostgreSQL is the first EventLedger adapter. Bare Git, Iroh, OCI,
immutable object storage, or other verified transports may replace or
supplement them without changing the kernel contract.

## Certified transition

Every licensed effect must bind the request and result to the exact normative
environment that admitted it:

```text
NormativeArtifactStore ─┐
SemanticArtifactStore ──┼─> kernel ─> certificate ─> EventLedger
SchemaArtifactStore ────┘                              ├─> projections
Evidence ArtifactStore ───────────────────────────────┘
                                                      └─> effects
```

A certified event records the effect identity, subject, action, input digest,
constitutive roots, evidence roots, derivation digest, witness digest, and
ordered event time. A mutable `status` column may summarize those events, but
it is not the fundamental fact.

## Repository-derived definitions

Each durable project designates a versioned SpruceGoose manifest in a
content-addressed artifact graph. The current adapter requires an exact
committed and pushed Forgejo revision before SpruceGoose may materialize
Project, Roadmap, Workflow, and reusable TaskDefinition content. Every
materialized definition binds to content identity plus the adapter receipt:
repository, commit, tree, path, digest, BlueprintRevision, and definition key.

TaskInstances carry runtime identity, lifecycle, evidence links, approvals,
assignments, locks, board placement, and outcomes. They must reference a
constitutive TaskDefinition. The current PostgreSQL adapter stores these
runtime facts. Inbox capture is a non-authoritative request surface; it does
not define work.

Existing TaskInstances and their lifecycle history are grandfathered as a
pre-ledger legacy epoch. They are not individually remediated, assigned
invented repositories, or backfilled with source revisions nobody reviewed.
The cutover records one content-addressed baseline snapshot and an explicit
`GrandfatheredStateAccepted` event. That event establishes the starting state
for forward replay; it does not certify the provenance or constitutional
licensing of each fact inside the snapshot.

Dogfood and migration fixtures that must not enter the operational baseline
remain quarantined. New TaskInstances admitted after the cutover epoch must
bind an exact constitutive TaskDefinition and produce certified events.

## Current implementation boundary

The Forgejo ArtifactStore adapter currently verifies exact commit, tree,
path bytes, and digest, and applies Project-scoped Roadmap and Workflow
definitions transactionally. PostgreSQL is still the live authority for task
rows and several mutable aggregates; the transactional outbox is not yet a
complete append-only EventLedger adapter.

Until the migration is complete, SpruceGoose must not claim full event-sourced
authority. The required sequence is:

1. Bind all new and actively maintained durable definitions to exact
   repository revisions; do not remediate historical TaskInstances one by one.
2. Introduce repository-authored TaskDefinitions and require them for new
   TaskInstances.
3. Project maintained constitutive definitions into their designated
   repositories, accept the verified legacy baseline once, and quarantine
   excluded fixtures.
4. Introduce certified append-only historical events with constitutive and
   evidentiary roots.
5. Rebuild current state from those events and demote mutable aggregate rows
   to projections only after parity and recovery proofs pass.
