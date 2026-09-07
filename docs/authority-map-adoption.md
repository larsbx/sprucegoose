# Authority Map Adoption

Status: **DRAFT — NON-OPERATIVE**

This document specifies how the authority map becomes authoritative: stored as
exact bytes in the content-addressed artifact store, adopted by a certified
human decision recorded in the event ledger, and read everywhere else only as a
projection.

It fills the gap named in §8 of [Deontic Spec Admission
Contract](deontic-spec-contract.md): the kernel has no certified `SpecAdopted`
primitive, so no document can currently reach `ADOPTED`. This specification
does not adopt itself. It is `DRAFT` until the primitive it describes exists and
a human-authorized adoption event binds its exact bytes.

## 1. What the authority map is

The authority map is the constitutional statement of who may do what: subjects,
actions, scopes, authority levels, expiry, and the grant/revocation epoch under
which they hold. It is the document the kernel consults to answer "was this
authorized", as distinct from `SpruceGoose.Actors.Grant`, which records
operational role membership and proves nothing constitutional (§2 of the
admission contract).

## 2. Where each concern lives

| Concern | Home | Identity |
|---|---|---|
| Exact constitutional bytes | `SpruceGoose.Kernel.ArtifactStore` | `cas:sha256:<digest>` |
| Adoption, supersession, revocation history | `SpruceGoose.Kernel.EventLedger` (PostgreSQL) | `CertifiedEvent` identity |
| Human-readable copy | Projected into ICM and the Systemwide SOP | none — a view |
| Authoring location | Git repository | none — a view |
| Current active version | Projection derived from the latest valid adoption event | derived |

Read this table as a separation of powers. The bytes say *what* the rule is. The
ledger says *that it was adopted, by whom, superseding what, and from when*.
Neither alone is authority; authority is the pair.

## 3. What is not authority

- **The ICM copy is not authority.** It is a rendering for humans.
- **The repository copy is not authority.** Git is where the bytes are authored
  and reviewed. A branch, tag, commit, or path is a mutable label, and D1
  already refuses labels as identity.
- **The filesystem path is not authority.** The production adapter stores bytes
  under `/var/lib/sprucegoose/artifacts/sha256/`, configured at
  `config/runtime.exs:86`. That path is a replaceable implementation detail. The
  `cas:sha256:` locator is what every other part of the system binds to, and it
  survives any change of adapter or host.
- **Operational role membership is not authority.** Restated from A2 because it
  is the failure this whole arrangement exists to prevent.

A view may be stale, forked, or wrong without any authority changing. That is
the point: divergence between a view and the adopted digest is a detectable
defect in the view, not an ambiguity about the rule.

## 4. Identity

The authority map is identified by `cas:sha256:<digest>`, where `<digest>` is
the lowercase hex SHA-256 of the exact canonical bytes, derived by
`SpruceGoose.Kernel.ContentID.derive/2` over
`SpruceGoose.Kernel.Canonical` encoding.

This is the locator form already in use for artifact receipts
(`lib/spruce_goose/artifacts/store.ex:62`), enforced at the database boundary by
the `harden_artifact_receipt_custody` migration, and checked when a task binds an
artifact (`lib/spruce_goose/workflows/task.ex:508`). The authority map reuses
that form rather than introducing a second identity scheme.

## 5. The adoption event

Adoption is one `SpruceGoose.Kernel.CertifiedEvent` appended to the ledger.

| Field | Value |
|---|---|
| `stream` | `constitution.authority_map` |
| `event_type` | `SpecAdopted` |
| `idempotency_key` | the adopted `cas:sha256:` locator |
| `roots` | the complete eight-root set in force at adoption |
| `payload` | the fields below |

Payload:

| Key | Meaning |
|---|---|
| `adopted` | `cas:sha256:` locator of the exact adopted bytes |
| `supersedes` | locator of the previously active map, or `null` for the first adoption |
| `effective_from` | the instant the adoption takes effect |
| `approved_by` | the human actor identity that authorized the decision |
| `authorization` | the `Authorization` identity the decision was derived through |
| `decision_reference` | the external decision record (review, signature, or receipt) |
| `grant_epoch` | the grant/revocation epoch the adoption is bound to |

`SpecSuperseded` and `SpecRevoked` share the stream and payload shape, carrying
`revoked`/`superseded` in place of `adopted`. Lifecycle stays monotonic per G5:
`DRAFT → CANDIDATE → ADOPTED → SUPERSEDED|REVOKED`.

Adoption never mutates a prior event. Replacement is a new adoption whose
`supersedes` names the outgoing digest, per G6.

## 6. Deriving the active version

The active authority map is a projection, not a stored pointer:

1. Read `constitution.authority_map` in ledger order.
2. Keep the latest `SpecAdopted` not later contradicted by a `SpecSuperseded` or
   `SpecRevoked` naming the same digest.
3. Verify its `approved_by` and `authorization` independently of the payload.
4. Fetch the bytes by locator and verify them with
   `ContentID.verify/2` before use.
5. If any step fails, refuse. There is no last-known-good fallback.

Because the answer is derived, replay reconstructs it exactly (P5), and no
component may write the active version directly (P3).

## 7. Invariants

These extend, and do not weaken, the admission contract's D/R/A/P/G invariants.

- **M1 — Pair authority:** Authority requires both the verified digest and a
  valid adoption event. Either alone refuses.
- **M2 — Views bind by digest:** Every projection — ICM, the Systemwide SOP,
  any rendering — records the `cas:sha256:` locator it was generated from. A
  projection without a locator is unusable as evidence of anything.
- **M3 — Drift is detectable, not authoritative:** A view whose recorded locator
  is not the active digest is reported as stale. It never changes what is
  authorized, and it never blocks the kernel.
- **M4 — Adapter neutrality:** No consumer may resolve the map by filesystem
  path, repository path, branch, or tag. Binding is by locator only.
- **M5 — External approval:** `approved_by` and `authorization` are verified
  against the constitutional path, never trusted from payload fields (G3).
- **M6 — First adoption is not self-bootstrapping:** The first `SpecAdopted`
  requires a human decision anchored outside the artifact (G4). An empty ledger
  authorizes nothing.

## 8. Refusals

| Condition | Refusal |
|---|---|
| Bytes absent from the artifact store | `missing_artifact` |
| Digest does not match fetched bytes | `content_mismatch` |
| No adoption event for the digest | `unadopted_spec` |
| Adoption approver or authorization unverifiable | `unauthorized_adoption` |
| `supersedes` names a digest that was never active | `broken_supersession` |
| Adoption event later than a revocation for the same digest | `revoked_spec` |
| Epoch in the adoption differs from the root-set epoch | `stale_grant` |
| Locator reused with different bytes | `idempotency_conflict` |
| Consumer resolves by path, branch, or tag | `unbound_reference` |

Fail-closed throughout, consistent with §6 of the admission contract.

## 9. Implementation gap

Nothing in §5 exists yet. `SpruceGoose.Kernel.ArtifactStore` is a port with
`get/2` and `verify/2` only, and the kernel has no `SpecAdopted` primitive or
verifier. Today the authority map exists as repository documentation, and the
architecture cannot formally adopt it by digest.

Build order:

1. A typed, content-addressed `SpecAdopted` primitive and verifier meeting the
   five requirements in §8 of the admission contract.
2. `SpecSuperseded` and `SpecRevoked` sharing its verification path.
3. The §6 active-version projection, with replay coverage.
4. Projection generators for ICM and the Systemwide SOP that stamp the locator
   (M2) and a drift check that reports staleness (M3).

Step 1 is the piece to build next. Until it exists and a human has approved
exact committed bytes, this document and the authority map it describes remain
non-operative, and OODA Decide/Act stays blocked.

## 10. Migration: unwinding repository-as-authority

"Repositories are the definition source of truth" was adopted in `a7cf038f`
(*Require repository-bound task admission*, 2026-08-21) and is superseded by
this specification. Git remains the authoring and review location; it stops
being the thing authority is read from.

Known surfaces, and what each should become:

| Surface | Today | Under this spec |
|---|---|---|
| `cli/command.ex:562` | `task add` refused unconditionally at the parser | refusal moves behind the adoption check, so the surface is governed rather than removed |
| `workflows/task.ex:350` | `validate_unbound_admission` requires `allow_unbound_task_admission` **and** `database != live_database` | admission binds to the active authority map digest |
| `cli/executor.ex` | inbox promotion cannot create executable work | promotion permitted where the active map authorizes it |
| `config/config.exs:68` | `allow_unbound_task_admission`, default `false` | retired; the flag is not a substitute for an adoption decision |

Two facts worth recording before anyone attempts this:

- The flag does not gate the CLI surface. `parse(["task", "add" | _])` refuses
  before any config is consulted, so flipping
  `allow_unbound_task_admission` changes nothing a caller can observe.
- Even where the flag is read, `task.ex:355` also requires
  `database != live_database`, so unbound admission is unreachable on production
  by construction.

A plain `git revert a7cf038f` is not the migration. Nine later commits build on
the blueprint machinery it introduced — including *Create projects from verified
blueprints*, *Fix existing-project blueprint application*, and *Bind one
immutable grandfathered baseline* — and the revert conflicts in
`config/config.exs` and `config/test.exs` on top of that. The repository-bound
path is replaced by adoption, not deleted underneath its dependents.
