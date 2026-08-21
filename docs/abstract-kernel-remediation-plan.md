# Abstract kernel remediation plan

This plan remediates the findings in the
[v0.2 conformance audit](audits/2026-08-21-abstract-deontic-kernel-v0.2.md)
without confusing repository authority, historical authority, and derived
operational state.

## Outcome

SpruceGoose will enforce one replayable path:

```text
content-addressed constitution
          |
          v
typed interpretation and resolution
          |
          v
authorization -> effect intent -> bounded executor
          |                              |
          +------> certified event <-----+
                         |
                         v
               rebuildable projections
```

Forgejo is the first constitutive `ArtifactStore` adapter. PostgreSQL is the
first historical `EventLedger` adapter. Neither product name enters the kernel
contract.

## Non-negotiable migration boundaries

- Existing PostgreSQL workflow rows remain operational authority until a full
  event replay produces byte-for-byte-equivalent projections and recovery is
  proven.
- Existing history is never upgraded into certified history by inventing
  constitutional roots. It receives an explicit legacy-import or genesis
  event with preserved provenance, or remains quarantined.
- Repository manifests contain Project, Roadmap, Workflow, and reusable
  TaskDefinition authority. They never contain runtime lifecycle, approvals,
  outcomes, queues, assignments, or claims that an effect occurred.
- Direct TaskInstance admission is not disabled until every durable project
  has a verified manifest route and an emergency rollback path.
- The generic Woodpecker execution agent is not retired until the bounded
  executor passes permit/refusal parity and production canary gates.
- Outbox delivery stays separate from historical truth. A dispatched outbox
  row may report a certified ledger event; it may not replace one.
- No destructive table removal occurs in this program. Demoted tables remain
  available for rollback until a separately authorized retirement phase.

## Dependency-ordered phases

| Phase | Deliverable | Audit findings | Exit gate |
| --- | --- | --- | --- |
| 0 | Adopt the exact v0.2 candidate plus a versioned SpruceGoose amendment artifact | F-01, F-10 | Exact bytes, hashes, review commit, successor/adoption identity, and Forgejo parity |
| 1 | Kernel ports and constitutional value types | F-02, F-05 | Pure tests for ContentID, ArtifactStore, EventLedger, KernelContext, Certificate, CertifiedEvent, EventIdentity; no database migration |
| 2 | Repository TaskDefinitions and immutable source bindings | F-03 | New TaskInstances require definition key plus BlueprintRevision; unbound admission refuses; legacy rows are explicitly classified |
| 3 | Minimal vertical constitutional slice | F-01, F-06, F-08, F-09 | One exact OntologyVersion → Proposition → Claim/Evidence → Justification → Norm/Grant → Resolution → Authorization chain replays deterministically |
| 4 | Bounded effect execution | F-07 | Executor accepts only a valid EffectIntent/permit, has no arbitrary-command input, records success/failure receipts, and cannot promote or deploy |
| 5 | Certified PostgreSQL EventLedger in shadow mode | F-02, F-04 | Transactional append, total stream position, idempotency key, immutable content, root verification, refusal tests, and retained legacy authority |
| 6 | Deterministic projectors and replay parity | F-04, F-09 | Empty-database replay matches task, dependency, board, TODO, permit, and receipt projections; repeated replay is identical |
| 7 | Constitutional breadth and historic validity | F-01, F-06, F-08, F-09 | Ontology mappings, reference bindings, conflict algebra, delegation, revocation, epochs, supersession, captured oracles, and historic replay pass |
| 8 | Controlled authority cutover | F-02, F-04 | Certified events become historical authority; mutable rows become projections; dual-read parity, canary, rollback, backup, and recovery proofs pass |
| 9 | Adapter and legacy retirement | F-07, F-10 | Generic worker and obsolete writers are stopped only after bounded-executor parity; stale docs are corrected; removal remains separately gated |

## Phase details

### Phase 0 — Constitutional adoption

Commit the supplied Markdown unchanged under a candidate/adopted constitution
path. Add a separate amendment artifact that introduces:

- `ArtifactStore.get/1` and `verify/1`;
- `EventLedger.append/1`, `read/1`, and `verify/1`;
- certified historical events distinct from audit observations;
- exact roots for schema, ontology, mapping, interpreter, evidence policy,
  norms, authority, agent charter, and captured observations;
- the `SpruceGoose.Kernel.*` namespace;
- ordering, idempotency, and projection-rebuild invariants.

Do not edit the supplied bytes in place. Adoption creates a reviewable relation
between the candidate and the amendment.

### Phase 1 — Ports before persistence

Define behaviours and immutable value types without Ash resources or database
tables. Use reference in-memory adapters to prove:

- content identity is derived from canonical bytes and algorithm identity;
- verification rejects altered bytes, wrong algorithms, and wrong adapter
  receipts;
- certified event identity excludes mutable delivery metadata;
- duplicate append is idempotent only for identical content;
- the same idempotency key with different content fails closed;
- kernel code does not pattern-match on Forgejo, filesystem, or PostgreSQL.

This phase creates the seam; it does not claim durable authority.

### Phase 2 — Repository-derived work definitions

Complete active task `tsk-20260821T142417Z-10cd15e2` before broad kernel
cutover:

1. Make TaskDefinition a first-class constitutive identity in the blueprint.
2. Bind TaskInstance to BlueprintRevision and definition key.
3. Refuse ad-hoc task content on the supported admission path.
4. Generate, review, commit, push, and apply manifests for durable projects.
5. Route the multi-repository `openclaw-system` project through an explicit
   roadmap-to-repository map.
6. Mark dogfood and unverifiable rows legacy/quarantined without fabricated
   source revisions.
7. Retain a temporary, logged legacy-admission path only for rollback; block
   it from creating new durable definitions.

### Phase 3 — Minimal vertical slice

Implement one narrow, application-neutral path rather than scaffolding every
resource in v0.2 at once. Each artifact is immutable and identifies its exact
inputs. Ash actions express domain intent; generic CRUD is internal only.

The first accepted case should license a harmless derivation action. Required
negative tests include undefined predicates, unbound referents, unsupported
claims, contested evidence, incompatible ontology/norm versions, insufficient
authority, expired grants, conflicts, and nondeterministic input omission.

### Phase 4 — Bounded executor

Make an Oban executor claim one EffectIntent or compatible DerivationPermit.
The action enum selects repository-owned deterministic mechanics; neither the
intent nor database stores a command string. The executor:

- verifies authorization and constitutive roots immediately before execution;
- uses an idempotency key fixed before the effect;
- emits distinct intended, attempted, succeeded, and failed facts;
- stores content-addressed receipts and captured external observations;
- cannot approve, promote, deploy, expand capability, or rewrite derivations.

Woodpecker may remain a scheduler/status adapter only if it cannot reintroduce
repository-controlled arbitrary execution. Otherwise remove it after canary
parity.

### Phase 5 — Shadow EventLedger

Add append-only tables and typed Ash actions in a forward-only migration. A
certified event includes at least:

```text
stream_id · position · event_id · idempotency_key · event_type
subject · action · inputs_root · context_root · certificate_root
evidence_root · result_root · occurred_at · recorded_at
```

Use PostgreSQL uniqueness and locking for stream order and idempotency. Protect
all historical content against update and delete. Delivery attempts, leases,
errors, and dispatch timestamps remain in outbox/projection tables, never in
the certified event identity.

During shadow mode, every accepted current mutation appends its candidate
event in the same transaction, but current rows remain authoritative. A
reconciliation job must identify missing, duplicate, reordered, or root-invalid
events and stop cutover.

### Phase 6 — Projection and recovery proof

Build projectors as pure folds plus transactional checkpoint writers. Test:

- full replay into an empty database;
- partial replay and resume;
- duplicate delivery;
- out-of-order input refusal;
- projector crash before and after checkpoint;
- concurrent readers during rebuild;
- current/live versus rebuilt parity;
- backup, restore, replay, and service restart.

Parity compares canonical structured values, not rendered text or row counts
alone.

### Phase 7 — Constitutional breadth

Expand only through end-to-end vertical additions. Every new artifact type
requires identity, version/succession rules, Ash policies/actions, database
constraints, historic replay behavior, and positive/refusal tests.

The exit suite covers all v0.2 K-01 through K-66 invariants and the added
ArtifactStore/EventLedger amendments. Any unsupported invariant remains red
and blocks conformance claims.

### Phase 8 — Authority cutover

Cut over one bounded project first. Required production gates:

- hashed pre-migration backup and tested restore path;
- exact deployed source and migration provenance;
- shadow append completeness for a defined observation window;
- dual projection parity under concurrent workload;
- successful empty-state rebuild and restart;
- explicit refusal of direct projection writes;
- rollback that restores the old reader/writer without deleting events;
- operator-visible health and lag metrics.

Only after the canary passes may additional projects move. The broad
`openclaw-system` project moves last.

## TDD contract for every phase

1. Add a failing positive case and adversarial refusal cases.
2. Implement the smallest typed Ash/domain or pure-port change.
3. Add PostgreSQL constraints for concurrency and direct-write bypasses where
   persistence is involved.
4. Review generated migrations and snapshots manually.
5. Run focused tests, format, warnings-as-errors compilation, full tests, and
   migration-drift checks.
6. Dogfood through the compiled socket CLI in a disposable database.
7. Deploy to Mama only with backup, rollback, health, concurrency, and exact
   source/publication parity proof.
8. Keep the phase task waiting if any negative case, replay proof, deployment
   proof, or remote parity check is absent.

## Completion definition

The remediation is complete only when:

- every applicable v0.2 and amendment invariant has executable evidence;
- exact constitutive inputs independently reconstruct every certificate;
- every protected effect traces to authorization, resolution, evidence,
  authority, norms, ontology, schema, and source;
- the certified ledger reconstructs operational state from an empty store;
- projections cannot acquire normative or historical authority through direct
  writes;
- historical facts cannot be rewritten by later constitutional versions;
- bounded execution has replaced arbitrary repository-controlled execution;
- production backup, restore, replay, canary, rollback, and remote parity are
  all proven.

