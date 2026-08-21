# Abstract deontic kernel v0.2 conformance audit

**Verdict:** SpruceGoose is **not conformant** with the supplied abstract
deontic kernel v0.2. It has several strong precursor controls, but no complete
constitutional derivation path and no certified historical event ledger.

This is a diagnosis, not remediation. It records the current boundary so the
implementation can proceed without relabeling partial mechanisms as a kernel.

## Scope and evidence

The audit compares the live SpruceGoose behavior and its directly inspected
source against:

- `SPEC_Abstract_Deontic_Kernel_v0.2.md`, SHA-256
  `b98ef9045aa55b005e07a3e792360e1c92e21f1f109b2b11f9a2b1246f5897c0`;
- the handoff bundle, SHA-256
  `cbf5a988509b34687428d5fba605ab5e73370912df1d218100079fd8f6a00d1a`;
- [`docs/authority-planes.md`](../authority-planes.md), commit
  `a94ce83b185a8c336256669222f8a0e2617ff2d1`.

The executable production baseline is `a169408`; every later source commit
through the audited `a94ce83` changes documentation only. Live evidence came
through the supported Mama Unix-socket client: version `0.1.0`, 16 projects,
the nine-roadmap `openclaw-system` projection, one applied blueprint revision,
two registered actors, eight grants, and zero currently failed outbox events.
Direct SSH inspection was unavailable because Mama refused the available key,
so the audit makes no claim about facts visible only through host or direct
production-database access.

## Conformance summary

| Constitutional area | Status | Current evidence |
| --- | --- | --- |
| Typed syntax and canonical inputs | Partial | Closed blueprint YAML, embedded task kinds, bounded identifiers, and deterministic digest derivation exist. There is no general Expression/AST/CanonicalForm model. |
| Ontology, reference, interpretation, proposition | Absent | No constitutional resources, versions, mappings, bindings, interpretations, or propositions exist. The historical knowledge graph is explicitly a read-only projection, not an ontology. |
| Epistemics | Absent | Artifact digests and task references exist, but there is no Claim, Support, Evidence, Justification, contradiction, or contested-result model. |
| Authority | Partial | Actor and scoped grant resources plus Ash policies enforce operator, approver, verifier, and executor roles. Decisions do not bind an exact grant version, delegation chain, revocation epoch, or authority root. |
| Deontics | Absent | Workflow gates encode application rules, but there is no versioned Norm, applicability result, conflict algebra, defeat trace, Resolution, or five-fold modality. |
| Temporality | Partial | Timestamps and successor-like revisions exist. There is no Epoch, temporal applicability, explicit retroactivity, or historic semantic/normative replay. |
| Authorization and effects | Partial | `DerivationPermit` is typed and excludes shell commands, but it is not produced by a constitutional Resolution and no bounded permit consumer is implemented. The generic CI worker remains outside this chain. |
| Historical ledger | Absent | AshEvents covers only Notes; the outbox stores immutable event content but transports mutable aggregate snapshots. Neither is the certified, ordered, independently verifiable EventLedger required by the authority contract. |
| Evidence custody | Partial | A local SHA-256 CAS and verified receipts exist. Receipt admission is stored in mutable task aggregates and is not certified by a historical event. |
| Projections and replay | Nonconformant | Current workflow rows remain operational authority. There is no demonstrated rebuild of task state from certified events with parity and recovery proof. |

## Findings

### F-01 — Critical: the constitutional kernel is absent

There are no `SpruceGoose.Kernel.Syntax`, Semantics/Ontology, Epistemics,
Deontics, Temporality, Effects, or Audit domains. Consequently the system
cannot produce the required typed chain from expression through proposition,
justification, resolution, authorization, intent, event, and receipt.

This fails the v0.2 structural, ontology, derivational, temporal, effect, and
replay invariants as a group. Existing lifecycle validation is deterministic
application logic; it is not a substitute for those independently answerable
constitutional questions.

### F-02 — Critical: no certified EventLedger exists

`SpruceGoose.Events.Event` is an AshEvents log attached only to Notes. It even
retains an explicitly labeled spike validation (`reject_me`) in production
source. No test demonstrates systemwide replay through this event log.

The transactional outbox is valuable delivery infrastructure: triggers insert
task and inbox snapshots, content columns are immutable, event keys are unique,
and dispatch uses locked claims. It is nevertheless not historical authority:

- events carry aggregate snapshots rather than certified transitions;
- they carry no ontology, schema, norm, authority, interpreter, evidence, or
  derivation roots;
- there is no ledger-wide order or verifiable chain;
- mutable dispatch state is mixed into the same rows;
- replay means retrying failed delivery, not reconstructing authoritative
  state.

Zero failed live outbox events proves current delivery health only. It does
not prove historical completeness or replayability.

### F-03 — Critical: task definitions do not license task instances

`TaskDefinition` is an embedded workflow value with `id`, `kind`,
`depends_on`, and `input`. A `Task` has no `definition_key`,
`blueprint_revision_id`, or constitutive content root. Its primary create
action still accepts operator-authored title, Definition of Done, runner, and
input directly.

Therefore repository blueprints can describe a workflow while runtime tasks
remain independently authored mutable facts. The system does not yet enforce
the adopted rule that a TaskInstance must cite an exact committed and pushed
TaskDefinition before admission.

### F-04 — High: mutable aggregates remain operational authority

Task lifecycle, descriptions, inputs, board placement, assignments, labels,
custom fields, evidence arrays, and outcomes are stored and updated directly
on operational rows. PostgreSQL triggers and optimistic locks provide strong
transactional integrity, but the rows are still the fact rather than a
projection of certified history.

No projector checkpoint, deterministic fold, full rebuild, parity comparison,
or recovery proof demotes these tables to derived state.

### F-05 — High: artifact custody is concrete rather than a kernel port

`SpruceGoose.Artifacts.Store` safely bounds regular-file intake, detects
mid-read mutation, hashes bytes, writes exclusively, syncs, sets mode `0400`,
and re-verifies collisions. It exposes `retrieve/4`, not the constitutional
`get(ContentID)` and `verify(ContentID)` capabilities, and is coupled to a
local filesystem root.

There is no typed ContentID shared across normative, semantic, schema, and
evidence stores, no adapter identity in kernel context, and no independent
verification contract. Filesystem permissions reduce accidental mutation but
do not themselves make the host-owned store immutable authority.

### F-06 — High: authority decisions are not version-bound

Ash policies correctly distinguish operator, approver, artifact verifier, and
derivation executor. Scoped grants and actor disablement are real fail-closed
controls. However, an authorization or derivation permit does not retain the
exact grant, delegation path, revocation state, policy root, or authority epoch
that licensed it.

`DerivationPermit` binds source and pipeline identities and has a deterministic
single-use lifecycle. It does not bind ontology, norms, evidence policy,
authority root, Resolution, or Authorization, so it cannot satisfy historical
authority replay.

### F-07 — High: the effect boundary is incomplete

The permit action enum (`test`, `build_release`, `verify_artifact`) and absence
of a shell-command field are sound. Tests prove role separation, deterministic
identity, legal lifecycle, and terminal rewrite refusal. No bounded executor
currently consumes only that permit, emits an `EffectIntent`, validates an
Authorization, appends a certified event, and stores a Receipt.

The permit is therefore an isolated authorization-shaped record, not yet the
exclusive gateway to protected effects.

### F-08 — Medium: evidence is hashed but not epistemically modeled

Task artifact receipts carry digest, size, locator, source identity, verifier,
and retrieval time, and database guards freeze them after readiness. They do
not express which proposition they support or attack, the inference used, the
admissibility policy, contradictions, confidence, or a Justification result.

This is custody evidence, not the v0.2 epistemic support graph.

### F-09 — Medium: temporal and replay semantics are missing

The system records timestamps and preserves several immutable receipts and
revisions, but it has no explicit Epoch or validity intervals for ontology,
interpretation, evidence policy, norms, grants, and mappings. It cannot prove
that replay selects the historically applicable constitutional environment or
that retroactivity was explicit.

### F-10 — Medium: current docs and implementation use different maturity levels

The authority-plane document truthfully labels the missing ledger and mutable
aggregate boundary. Other older diagrams and prose still describe PostgreSQL
as undifferentiated authority. Until projections, events, and constitutive
artifacts are consistently labeled, readers can mistake transactional
integrity for constitutional or historical authority.

## Controls worth preserving

The migration should retain these demonstrated strengths:

- exact Forgejo commit/tree/path/digest blueprint verification;
- atomic blueprint validation and materialization with immutable revision
  receipts;
- Ash policy separation and scoped actor grants;
- SOP digest acknowledgment and explicit lifecycle transitions;
- database constraints for graph membership, cycles, predecessor readiness,
  artifact readiness, and immutable custody receipts;
- deterministic task, dependency, outbox, blueprint, and permit identities;
- outbox content immutability, unique event keys, bounded retry, stale-lease
  refusal, and locked claims;
- bounded content-addressed intake and collision verification;
- typed derivation actions with no arbitrary command field.

These are implementation assets, not evidence of full conformance.

## Required conformance sequence

1. Adopt the candidate constitution as an exact content-addressed artifact,
   with the authority-plane amendments recorded as a successor/adoption
   artifact rather than edits hidden in database rows.
2. Define `ArtifactStore` and `EventLedger` behaviours plus typed ContentID,
   KernelContext, Certificate, CertifiedEvent, and EventIdentity values.
3. TDD the smallest complete constitutional path under
   `SpruceGoose.Kernel.*`; keep every intermediate artifact independently
   inspectable and content-bound.
4. Make repository TaskDefinitions first-class constitutive artifacts and
   refuse unbound TaskInstance admission.
5. Make the bounded executor accept only an authorized EffectIntent or permit
   derived from a Resolution; retain receipts and failure without rewriting
   derivation history.
6. Append certified events transactionally, build projections from them, and
   prove full rebuild, parity, idempotence, ordering, and recovery before
   demoting mutable workflow rows.
7. Add historical replay tests across ontology, mapping, schema, norm, grant,
   revocation, captured observations, failed effects, and supersession.

## Verification

Focused evidence suite:

```text
79 tests, 0 failures
```

It covered actors/policies, authorization lint, blueprints, derivation
permits, deterministic identifiers, ledger-import custody, and transactional
outbox behavior. Passing precursor tests do not change the nonconformance
verdict because the absent constitutional resources and replay path have no
tests to pass.

