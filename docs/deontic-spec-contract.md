# Deontic Spec Admission Contract

Status: **DRAFT — NON-OPERATIVE**

This document defines the primitives and invariants that a deontic specification must satisfy before the current SpruceGoose kernel may treat it as a candidate source of authorization. It is for spec authors, reviewers, and kernel implementers.

This document does not adopt itself, grant authority, authorize an effect, or move historical authority. The current kernel has no certified `SpecAdopted` primitive. Until that gap is implemented and a human-authorized adoption receipt binds the exact document bytes, every deontic spec remains non-operative.

## 1. Kernel authorization path

The current constitutional path is deterministic and content-addressed:

```text
eight exact roots
       │
       ▼
OntologyVersion → Proposition → Evidence → Claim → Justification
       │                                            │
       └──────────────→ Norm → Grant ──────────────┤
                                                    ▼
                                              Resolution
                                                    │
                                                    ▼
                                             Authorization
                                                    │
                                                    ▼
                                        EffectIntent(executed? = false)
```

The path may authorize only the allowlisted `verify_artifact` action today. An `EffectIntent` is an inert description; it is not executable authority.

## 2. Kernel primitives

| Primitive | Required meaning | Current source |
|---|---|---|
| `ContentID` | SHA-256 identity of exact bytes | `SpruceGoose.Kernel.ContentID` |
| Canonical bytes | Versioned, deterministic encoding with sorted string-keyed maps | `SpruceGoose.Kernel.Canonical` |
| `RootSet` | Exact ontology, schema, norm, policy, grant epoch, agent charter, interpreter, and evidence-policy roots | `SpruceGoose.Kernel.Constitution.RootSet` |
| `OntologyVersion` | Defined predicates and bound referents under exact ontology and schema roots | `SpruceGoose.Kernel.Constitution.OntologyVersion` |
| `Proposition` | One predicate, referent, and deterministic input identity | `SpruceGoose.Kernel.Constitution.Proposition` |
| `Evidence` | One observation tied to a proposition and classified as accepted or contested | `SpruceGoose.Kernel.Constitution.Evidence` |
| `Claim` | A proposition/evidence binding with explicit support status | `SpruceGoose.Kernel.Constitution.Claim` |
| `Justification` | A supported claim interpreted under exact evidence-policy and interpreter roots | `SpruceGoose.Kernel.Constitution.Justification` |
| `Norm` | A norm and policy declared compatible with the ontology version | `SpruceGoose.Kernel.Constitution.Norm` |
| Constitutional `Grant` | Subject, action, authority, expiry, charter, and exact grant/revocation epoch | `SpruceGoose.Kernel.Constitution.Grant` |
| `Resolution` | Conflict evaluation joining justification, norm, and grant | `SpruceGoose.Kernel.Constitution.Resolution` |
| `Authorization` | Exact subject/action authority derived from one resolution | `SpruceGoose.Kernel.Constitution.Authorization` |
| `EffectIntent` | Non-executed, content-addressed intent tied to one authorization | `SpruceGoose.Kernel.Constitution.EffectIntent` |
| `CertifiedEvent` | Canonical event content, exact roots, stream, type, and idempotency key | `SpruceGoose.Kernel.CertifiedEvent` |
| `EventLedger` | Ordered immutable append, read, and independent content verification | `SpruceGoose.Kernel.EventLedger` |
| Derivation `Permit` | One bounded derivation identity bound to source, task, action, input, and all eight roots | `SpruceGoose.Derivations.Permit` |
| `OutcomeReceipt` | One append-only terminal outcome per permit | `SpruceGoose.Derivations.OutcomeReceipt` |
| `StateSource` / `ShadowSnapshot` | Provider-neutral, immutable runtime observation; never runtime authority | `SpruceGoose.Runtime.StateSource` and `ShadowSnapshot` |

The constitutional `Grant` is distinct from an operational actor-role grant in `SpruceGoose.Actors.Grant`. A deontic spec must never treat possession of an operational role as proof that the constitutional chain succeeded.

## 3. Required spec envelope

A candidate deontic spec must declare all of the following as content-addressed data:

1. Spec identity, version, canonicalization version, and exact source bytes.
2. The complete eight-root set. Missing, extra, malformed, or substituted roots invalidate the candidate.
3. Ontology predicates and referents used by every proposition, norm, grant, and effect class.
4. Evidence classes, acceptance rules, contestation behavior, and the exact evidence-policy root.
5. Norms and policies, including their ontology-compatibility rule.
6. Subjects, actions, scopes, authority levels, expiry rules, and grant/revocation epoch.
7. Conflict-detection and resolution rules.
8. Allowlisted effect classes. Absence from the allowlist means refusal.
9. Exception and amendment rules, including who may propose, review, adopt, supersede, or revoke exact bytes.
10. A human adoption boundary external to the candidate artifact itself.

Normative overlays such as a Māqāṣid signature may supply ontology, norm, policy, or evidence-policy content. They receive no special bypass: the exact overlay bytes must be content-addressed into the relevant roots and pass the same adoption and revocation rules.

## 4. Mandatory invariants

### Identity and determinism

- **D1 — Exact-byte identity:** Every normative artifact and referenced input has a SHA-256 `ContentID`. A label, filename, branch, or mutable URL is not an identity.
- **D2 — Canonical encoding:** Identity is derived from the kernel's versioned canonical bytes. Maps use string keys and deterministic ordering.
- **D3 — Deterministic input:** Every proposition identifies its input. Omission refuses as `nondeterministic_input`.
- **D4 — Substitution resistance:** Rebuilding the path from the same roots and request must produce the identical path. Any changed link refuses as `substituted_artifact`.

### Root and semantic closure

- **R1 — Exact root set:** The spec binds ontology, schema, norm, policy, grant epoch, agent charter, interpreter, and evidence-policy roots.
- **R2 — Root propagation:** Every constitutional artifact, permit, receipt, and certified event carries or transitively binds the same root-set identity.
- **R3 — Ontology closure:** Every predicate is defined and every referent is bound by the selected ontology version.
- **R4 — Norm compatibility:** A norm cannot participate unless it is compatible with the exact ontology version.
- **R5 — Evidence closure:** A claim requires accepted evidence. Contested evidence cannot authorize.

### Authority and decision safety

- **A1 — Subject/action equality:** Requested subject and action must exactly match the grant subject and action.
- **A2 — Sufficient authority:** Insufficient authority always refuses; operational role membership cannot substitute for constitutional authority.
- **A3 — Fresh epoch:** The grant epoch in the request equals the root-set grant/revocation epoch.
- **A4 — Expiry:** Authorization time is strictly earlier than grant expiry.
- **A5 — Conflict freedom:** Any unresolved conflict prevents an authorized resolution.
- **A6 — Effect allowlist:** Only explicitly licensed actions can produce an intent. The current allowlist contains only `verify_artifact`.
- **A7 — Inert intent:** `EffectIntent.executed?` is false. A separate bounded executor and fresh authorization are required for any future effect mechanism.

### Persistence, replay, and outcomes

- **P1 — Certified append:** Operative history is recorded as ordered `CertifiedEvent` values with the complete root set.
- **P2 — Idempotency:** Reusing a stream/idempotency key succeeds only for identical canonical content; changed content refuses.
- **P3 — Immutability:** Certified events, projections, permits, and outcome receipts refuse unauthorized update or deletion at the database boundary.
- **P4 — One terminal outcome:** A derivation permit remains immutable and may produce at most one terminal `OutcomeReceipt` plus one certified outcome event in the same transaction.
- **P5 — Deterministic replay:** Rebuilding from the accepted baseline plus contiguous certified events produces the same authoritative projection digest.
- **P6 — Provider neutrality:** Runtime adapters emit only the versioned `StateSource` envelope. Provider names, commands, payload schemas, and session internals do not enter the constitutional kernel.

### Adoption and revocation

- **G1 — No self-adoption:** A candidate cannot become policy by setting a field inside its own payload.
- **G2 — Exact-byte adoption:** Adoption binds the candidate spec `ContentID`, all eight roots, adoption decision identity, authorized human actor, and grant/revocation epoch.
- **G3 — Certified human decision:** Adoption requires a separately verified, append-only receipt or certified event issued through the constitutional path. A signer name string is not a signature or authorization.
- **G4 — External trust anchor:** Freeze manifests and adoption receipts are anchored outside the mutable candidate package.
- **G5 — Monotonic lifecycle:** A spec moves only `DRAFT → CANDIDATE → ADOPTED → SUPERSEDED|REVOKED`. Revoked or superseded roots cannot authorize new work.
- **G6 — Amendment by replacement:** Amendments create new bytes, roots, identity, review, and adoption. They do not rewrite an adopted artifact.

## 5. Conformance states

| State | Meaning | May authorize? |
|---|---|---|
| `DRAFT` | Incomplete or unreviewed content | No |
| `CANDIDATE` | Mechanical invariants pass for exact bytes | No |
| `ADOPTED` | A separately authorized human decision binds the exact candidate and roots | Only after the kernel verifies the adoption receipt |
| `SUPERSEDED` | Replaced by a newer adopted identity | No new authorization |
| `REVOKED` | Invalidated at a later grant/revocation epoch | No |

The current SpruceGoose kernel can verify the constitutional path, certified events, permits, and receipts, but it cannot yet establish `ADOPTED` because no `SpecAdopted` primitive or verifier exists. Consequently this document and every spec evaluated under it remain `DRAFT` or `CANDIDATE` only.

## 6. Required refusals

A conforming implementation must preserve the current fail-closed outcomes:

| Condition | Refusal |
|---|---|
| Missing or malformed root | `missing_root` / `invalid_root` |
| Missing deterministic input | `nondeterministic_input` |
| Undefined predicate or unbound referent | `undefined_predicate` / `unbound_referent` |
| Unsupported claim or contested evidence | `unsupported_claim` / `contested_evidence` |
| Incompatible ontology and norm | `incompatible_ontology_and_norm` |
| Stale or expired grant | `stale_grant` / `expired_grant` |
| Insufficient authority | `insufficient_authority` |
| Subject/action mismatch or unlicensed action | `unauthorized_effect` |
| Unresolved conflict | `unresolved_conflict` |
| Changed artifact in a sealed path | `substituted_artifact` |
| Reused idempotency key with changed content | `idempotency_conflict` |

Unknown, ambiguous, unimplemented, or unverified states refuse. There is no permissive fallback.

## 7. Admission checklist

A reviewer may mark a spec `CANDIDATE` only when all answers are yes:

- Are the exact spec bytes and canonicalization version identified?
- Are all eight roots present, valid, and propagated?
- Are predicates defined, referents bound, evidence accepted, and norms compatible?
- Are subject, action, authority, epoch, expiry, and conflicts explicit?
- Are effects allowlisted and represented only as inert intents?
- Do substitution, missing-root, stale-epoch, expiry, conflict, and unauthorized-effect tests fail closed?
- Can certified history replay deterministically without direct projection writes?
- Is the runtime boundary provider-neutral?
- Is adoption external to the candidate and bound to an authorized human decision?
- Is revocation monotonic and amendment replacement-only?

Failure or absence of any item leaves the artifact `DRAFT`.

## 8. Implementation gap before adoption

The next kernel slice must add a typed, content-addressed adoption primitive and verifier before this contract can become operative. At minimum it must:

1. Bind the exact spec `ContentID`, all eight roots, human actor identity, authorization identity, decision reference, and grant/revocation epoch.
2. Verify the human actor and authorization independently of candidate-controlled fields.
3. Append one immutable certified adoption event with conflict-safe idempotency.
4. Refuse self-declared, stale, substituted, unsigned, unauthorized, superseded, or revoked adoption claims.
5. Preserve deterministic replay and projection-write refusal.

Until that implementation and an explicit human approval of exact committed bytes both exist, OODA Decide/Act and historical-authority cutover remain blocked.
