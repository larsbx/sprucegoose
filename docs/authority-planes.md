# SpruceGoose authority planes

SpruceGoose separates rules, events, evidence, and views so no storage system
gains an authority it cannot safely carry.

> Repositories define what may happen. The ledger records what did happen.
> Evidence proves what was observed. Projections explain the result.

## Authority map

| Plane | Canonical content | Required properties |
| --- | --- | --- |
| Constitutive | Kernel code, schemas, migrations, policies, ontologies, agent charters, capabilities, oracle definitions, Project/Roadmap/Workflow/TaskDefinition manifests, deployment declarations | Reviewed repository revision; content-addressed and independently reconstructible |
| Operative | Requests, licensed transitions, commitments, executions, memberships, orders, jobs, workflow state, and terminal outcomes | Append-only PostgreSQL event ledger with transactional identities and ordering |
| Evidentiary | Runtime artifacts, observations, witnesses, receipts, logs admitted as evidence, and oracle outputs | Content-addressed object custody; digest and provenance committed by an operative event |
| Projection | Current rows, dashboards, queues, reports, Markdown, JSON, DOT, and search indexes | Rebuildable from the three authoritative planes; never accepted as authority input |

The constitutive plane cannot assert that an event happened. The operative
plane cannot create a rule merely by storing a row. The evidentiary plane
cannot license an effect merely because bytes exist. A projection cannot
authorize any mutation.

## Certified transition

Every licensed effect must bind the request and result to the exact normative
environment that admitted it:

```text
repository roots                         evidence roots
kernel · policy · ontology · schema      input · witness · artifact
             \                              /
              \                            /
               execution kernel decision
                         |
                         v
             append-only operative event
                         |
                         v
                rebuildable projections
```

An operative event records the effect identity, subject, action, input digest,
constitutive roots, evidence roots, derivation digest, witness digest, and
ordered event time. A mutable `status` column may summarize those events, but
it is not the fundamental fact.

## Repository-derived definitions

Each durable project designates one Forgejo repository and a versioned
SpruceGoose manifest. Project, Roadmap, Workflow, and reusable TaskDefinition
content must exist in a committed and pushed revision before SpruceGoose may
materialize it. Every materialized definition binds to repository, commit,
tree, path, digest, BlueprintRevision, and definition key.

PostgreSQL TaskInstances carry runtime identity, lifecycle, evidence links,
approvals, assignments, locks, board placement, and outcomes. They must
reference a committed TaskDefinition. Inbox capture is a non-authoritative
request surface; it does not define work.

Historical dogfood and migration fixtures without provable repository
ownership remain explicitly quarantined. Migration must never assign them an
invented repository or backfill a source revision nobody reviewed.

## Current implementation boundary

The repository-blueprint path currently verifies exact Forgejo commit, tree,
path bytes, and digest, and applies Project-scoped Roadmap and Workflow
definitions transactionally. PostgreSQL is still the live authority for task
rows and several mutable aggregates; the transactional outbox is not yet a
complete append-only operative ledger.

Until the migration is complete, SpruceGoose must not claim full event-sourced
authority. The required sequence is:

1. Bind all durable definitions to exact repository revisions.
2. Introduce repository-authored TaskDefinitions and require them for new
   TaskInstances.
3. Project verified durable projects into their designated repositories and
   quarantine unverifiable historical fixtures.
4. Introduce certified append-only operative events with constitutive and
   evidentiary roots.
5. Rebuild current state from those events and demote mutable aggregate rows
   to projections only after parity and recovery proofs pass.

