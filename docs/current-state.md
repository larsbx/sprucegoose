# Current state

Verified 2026-08-22 under task `tsk-20260822T094711Z-a55aa8a2`.

## Production authority

- Mama runs the persistent SpruceGoose OTP service backed by PostgreSQL 19
  Beta 2. The deployed application commit is
  `3b51983bd63e4054e685432a871f39f8a8211de8`; its tree is
  `6b2f28b8a5d13e104345f6db761c4b0d527a9a4a`. The governed
  `transactional-shadow-events-20260822` transaction retained PostgreSQL 19
  Beta 2 and activated transactional certified-event shadowing.
- The thin `sprucegoose` client talks to the owner-only Unix socket. Direct
  application startup is not a normal operator path and must refuse while the
  authority marker names Mama.
- Ash/PostgreSQL owns projects, roadmaps, workflows, task instances, lifecycle
  transitions, actors, grants, receipts, permits, and evidence links.
- Repository-bound BlueprintRevisions and TaskDefinitions are the reviewed
  admission surface. Mutable operator task creation is retired.
- Direct Project, Roadmap, and Workflow creation, rename, and removal commands
  are absent from the supported CLI and refuse through legacy entry points.
  Exact verified `blueprint apply` operations may create a repository-defined
  Project and materialize its hierarchy in one transaction. Invalid manifests
  roll back the Project and BlueprintRevision together. Existing hierarchy
  rows remain readable.

PostgreSQL 19 Beta 2 is an explicit production deviation. It is operationally
verified but is not a supported GA baseline, so production and development
parity remains weaker than the intended Twelve-Factor baseline.

## Artifact boundary

- Successful artifact verification records a digest-bound permit and stores
  immutable content-addressed bytes.
- A root-managed `artifact-signer` identity holds the Ed25519 private key. The
  SpruceGoose/Oban executor cannot read or replace it.
- The signer has no IP network, no CAS write access, no repository, build, or
  deployment credentials, and no SpruceGoose mutation role. It signs only a
  succeeded, digest-matching `verify_artifact` permit.
- The signer deployment is bound to
  `root/woodpecker-deploy@7c12ab7130e28dc6fddafcdc327ab058cd2161b3`.

## Delivery architecture status

Forgejo is the source authority. Woodpecker runs loopback-only CI and governed
release builds. The SpruceGoose Oban executor performs the bounded derivation
actions. SpruceGoose governs task admission, verification permits, and
deployment authorization. Independent signing and immutable CAS custody are
live.

Assured Mode is **not** claimed. OpenShip or an approved equivalent realization
plane is not deployed, the dedicated isolated build runner is incomplete, and
the full fourteen paired permit/refuse acceptance matrix has not passed as one
release gate.

## Authority-cutover status

The first persistence-independent kernel seam is implemented under convergence
task `tsk-20260821T142417Z-10cd15e2`. It provides typed SHA-256 content
identities, certified events whose identity excludes mutable delivery
metadata, ArtifactStore and EventLedger ports, and reference in-memory
adapters. Focused tests prove altered-content and wrong-adapter refusal plus
idempotent append only for byte-identical events.

The deployed kernel also provides one deterministic, content-addressed path
from an exact ontology version through proposition, evidence, claim,
justification, norm, grant, resolution, authorization, and an unexecuted
`EffectIntent`. It refuses missing or substituted roots, undefined predicates,
unbound referents, unsupported or contested evidence, incompatible norms,
stale or expired grants, insufficient authority, conflicts, omitted input
identity, and unauthorized effects. The only licensed action in this slice is
`verify_artifact`; the path stores no command and cannot execute an effect.

The deployed PostgreSQL EventLedger now appends immutable, per-stream ordered
certified events with exact content identities, required constitutional roots,
and conflict-safe idempotency. Database constraints recheck identities and
required roots, and a trigger refuses updates and deletes. Its recovery,
separate-session concurrency, retry, and conflict behavior has passed. The
supported mutation path now appends one root-valid candidate event in the same
transaction as each accepted mutation in the baseline replay scope; a refused
append rolls the mutation back. Reconciliation checks task outbox coverage and
contiguous stream positions. The production stream currently contains two
candidate events at positions 1 and 2, with no missing task events or malformed
streams. A fresh logical dump restored both events and all eight roots into a
disposable database. No historical roots were invented, and mutable workflow
rows remain authority.

This is not a production historical-authority cutover. A governed
`GrandfatheredStateAccepted` baseline, the shadow-append observation window,
deterministic projection rebuild, dual-read parity, rollback proof, and
direct-projection-write refusal remain required. The shadow-append observation
window has started but is not itself an authority change. Jimbo is excluded
from the first cutover wave. A bounded non-Jimbo project will canary first, and
`openclaw-system` will move last.

## Repository documentation policy

This page is the only document that claims to describe the live overall state.
Implementation documents describe durable contracts. Operational runbooks
describe procedures. Dated audits are retained only while they are an active
conformance baseline; superseded reports and generated evidence belong in Git
history or owner-only external custody, not in the working tree.

The active conformance baseline is
[`audits/2026-08-21-abstract-deontic-kernel-v0.2.md`](audits/2026-08-21-abstract-deontic-kernel-v0.2.md),
with work ordered by
[`abstract-kernel-remediation-plan.md`](abstract-kernel-remediation-plan.md).
