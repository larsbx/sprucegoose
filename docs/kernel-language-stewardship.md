# Kernel language and runtime stewardship

Status: **DRAFT — NON-OPERATIVE**

This document governs how SpruceGoose may introduce and maintain Elixir/Ash,
Gleam, and Rust inside the abstract kernel. It is a repository-stewardship
contract, not a constitutional adoption artifact. It does not move production
authority, authorize effects, alter historical roots, or make the current
kernel conformant by declaration.

It complements:

- `docs/abstract-kernel-remediation-plan.md`;
- `docs/deontic-spec-contract.md`;
- `docs/authority-planes.md`;
- `docs/current-state.md`;
- `docs/decisions/2026-09-08-kernel-and-ledger-shape.md`.

Where those documents define authority, conformance, or migration boundaries,
they win. This document only governs implementation placement and repository
stewardship.

## 1. Governing principle

The repository SHALL preserve this division:

```text
authoritative artifacts and operational state
                |
                v
          Elixir / Ash
 persistence · transactions · supervision · effects
                |
                v
             Gleam
 typed pure constitutional logic and state transitions
                |
                v
              Rust
 compiled representations and bounded computational primitives
```

The intended rule is:

> **Ash owns durable application coordination, Gleam owns pure constitutional
> logic, and Rust owns rebuildable compiled representations or bounded
> computational primitives.**

No language receives authority merely because it is faster, more strongly
typed, or closer to the machine.

## 2. Source-of-truth boundary

The repository SHALL distinguish authoritative state from derived state.

### 2.1 Authoritative

Authoritative inputs remain versioned, reviewable artifacts and durable
application records, including as applicable:

- ontology and mapping artifacts;
- norm and policy artifacts;
- authority and grant artifacts;
- state-machine definitions;
- canonical semantic inputs;
- certified historical events;
- effect intents and receipts;
- exact implementation and schema provenance required by active contracts.

These identities MUST use stable, replayable identifiers.

### 2.2 Derived

The following MAY be generated or cached and MUST be rebuildable from
authoritative inputs:

- dense ordinals;
- bitsets and roaring bitmaps;
- ontology transitive closures;
- predicate-to-rule indexes;
- capability indexes;
- compiled state transition tables;
- interned formula/proposition tables;
- hash-consed DAGs;
- temporal lookup structures;
- replay accelerators;
- native snapshots.

A derived ordinal such as `342` SHALL NEVER become the durable identity of a
concept, norm, state, event, or capability.

## 3. Elixir and Ash stewardship

Elixir/Ash SHALL remain the default implementation surface for:

- Ash Domains, Resources, actions, policies, and validations;
- PostgreSQL persistence and migrations;
- EventLedger and ArtifactStore adapters;
- transactional coordination;
- supervision trees;
- Oban jobs and effect execution orchestration;
- Phoenix, CLI, socket, and API surfaces;
- external adapters and replaceable provider ports;
- retries, leases, queue state, delivery state, and operational telemetry;
- durable intent and receipt recording.

Elixir/Ash SHALL own the durable machine head when a state machine is persisted.

Example:

```text
MachineHead
  machine_id
  stable_state_name
  version
  updated_at
  last_transition_id
```

Every accepted durable transition SHALL be journaled or represented by the
active certified-history contract before the materialized head is advanced.

### 3.1 Prohibited use

Elixir callbacks SHALL NOT become a hidden second implementation of
constitutional transition legality once that logic is assigned to Gleam.

Ash policies MAY still enforce access to an action. They SHALL NOT silently
redefine the underlying state-transition algebra.

## 4. Gleam stewardship

Gleam SHOULD be used when a kernel component satisfies all of the following:

1. its input and output can be represented as immutable values;
2. the function is deterministic for fixed explicit inputs;
3. no database access, external I/O, process registry, clock read, or hidden
   application environment lookup is required;
4. the relevant state space is closed enough that exhaustive variants provide
   meaningful correctness pressure;
5. the function can be replayed independently of the Ash resource that stores
   its result.

Preferred Gleam responsibilities include:

- finite-state-machine transition legality;
- semantic intermediate representations;
- proposition and formula algebra;
- epistemic assessment algebra;
- authority and delegation algebra;
- deontic conflict and resolution algebra;
- temporal validity evaluation;
- derivation structures;
- pure validation and normalization.

Representative public shape:

```text
transition :
  MachineDefinition
  -> MachineState
  -> Event
  -> Context
  -> Result(Transition, TransitionError)
```

and:

```text
resolve :
  SemanticInputs
  -> EvidenceInputs
  -> AuthorityInputs
  -> NormativeInputs
  -> TemporalContext
  -> Result(Resolution, ResolutionError)
```

### 4.1 Gleam MUST NOT own

Gleam SHALL NOT become the owner of:

- database transactions;
- runtime leases;
- actor sessions;
- effect execution;
- retries;
- external provider clients;
- mutable application configuration;
- production authority records.

### 4.2 Closed algebra requirement

Where Gleam defines a constitutional sum type, the repository SHALL prefer a
closed variant over ad-hoc atom/string conventions.

Examples include:

```text
Modality =
  Obligatory
  | Forbidden
  | Permitted
  | Recommended
  | Discouraged
```

and:

```text
Assessment =
  Accepted
  | Rejected
  | Contested
  | Insufficient
  | Unknown
```

Adding a variant is therefore a review-visible compatibility change.

## 5. Rust stewardship

Rust SHALL be introduced only behind a narrow, deterministic boundary.

Preferred Rust responsibilities are:

- compact bitsets or roaring bitmaps;
- ontology closure and reachability;
- sparse/dense graph compilation;
- structural hashing;
- canonical byte encoding;
- signature and cryptographic primitives;
- hash-consing and interning at scale;
- compiled automata tables;
- high-throughput replay verification;
- bulk immutable snapshot compilation.

Rust SHOULD implement **mechanics**, not constitutional policy.

Example split:

```text
Gleam decides:
  which candidate sets must be intersected

Rust performs:
  bitmap A AND bitmap B AND bitmap C
```

### 5.1 Promotion gate for Rust

A new Rust dependency or native component requires one of these reviewable
justifications:

- profiling shows the candidate path accounts for at least 10% of relevant CPU
  time or memory pressure under a representative workload; or
- an isolated prototype demonstrates at least 2x throughput improvement or at
  least 30% memory reduction for the same semantics; or
- the operation is a byte-exact, cryptographic, memory-layout, SIMD, or
  algorithmic primitive for which Rust provides a materially safer or more
  auditable implementation.

A benchmark alone does not permit moving durable authority into Rust.

The PR SHALL include the workload, baseline, measurements, and semantic
equivalence tests.

### 5.2 NIF boundary

Small bounded operations MAY use a Rust NIF when all of these hold:

- runtime is predictably bounded;
- inputs and outputs are ordinary immutable values or binaries;
- failure maps to an explicit typed error;
- the NIF cannot mutate durable state;
- a crash cannot create an effect without a durable intent.

Examples:

- bitmap membership/intersection;
- structural hash;
- signature verification;
- compact automaton transition;
- small canonical encoding operation.

Large or unpredictable computations SHOULD run in a dirty scheduler or outside
the ordinary scheduler boundary, and MAY require a supervised port/worker
instead of a normal NIF.

Examples:

- rebuilding a large ontology closure;
- compiling a large corpus;
- bulk replay;
- large graph algorithms.

## 6. State-machine stewardship

The kernel SHALL NOT use one giant lifecycle enum spanning syntax,
interpretation, evidence, authority, normativity, authorization, and effects.

It SHALL use orthogonal machines joined by typed artifacts.

Candidate machines include:

- ontology-version lifecycle;
- ontology-mapping lifecycle;
- interpretation session;
- epistemic assessment;
- authority-grant lifecycle;
- norm-version lifecycle;
- resolution lifecycle;
- authorization lifecycle;
- effect-intent lifecycle;
- replay-verification lifecycle.

### 6.1 Canonical state identity

State names and event names are stable repository-facing identities.

Compiled local ordinals MAY be used inside a snapshot:

```text
:draft       -> 0
:active      -> 1
:superseded  -> 2
:revoked     -> 3
```

but the ordinal is scoped to the compiled snapshot and SHALL NOT be persisted
as the sole durable identity.

### 6.2 Transition representation

A compiled machine MAY use:

```text
allowed_events[state_ordinal] : bitset<EventOrdinal>
next_state[state_ordinal][event_ordinal] : StateOrdinal
```

provided the compiler can reproduce it deterministically from the reviewed
machine definition.

### 6.3 Durable transition rule

For a persisted machine:

1. read the current durable head;
2. evaluate the transition with explicit context;
3. compare-and-swap or otherwise atomically verify the expected version;
4. append the transition/history artifact required by the active history
   contract;
5. update the materialized head in the same transaction where the persistence
   model permits;
6. emit no protected external effect until the durable effect-intent boundary
   is crossed.

## 7. Optimized data-structure contract

Optimized structures SHALL be treated as compiled views.

### 7.1 Ontology

A compiled ontology snapshot MAY contain:

```text
CompiledOntology
  ontology_version_id
  concept_id <-> local_ordinal
  subsumption_closure[ordinal] -> bitset
  disjointness[ordinal]        -> bitset
  relation indexes
  mapping indexes
```

For example, once compiled:

```text
A subset-of B ?
  => test bit B in closure[A]
```

and:

```text
common supertypes(A, B)
  => closure[A] AND closure[B]
```

The stable concept identities and ontology version remain authoritative.

### 7.2 Deontic candidate selection

Candidate norms MAY be selected by bitmap intersection:

```text
rules_for_predicate
AND rules_active_at_epoch
AND rules_for_authority_scope
AND rules_matching_context
= candidate rule ordinals
```

Gleam or Elixir owns the semantics of which sets participate. Rust MAY own the
fast intersection primitive.

### 7.3 Formula/proposition interning

Large immutable formula or proposition sets MAY use hash-consing or interning.
The intern key MUST derive from canonical semantic identity, not process-local
address or insertion order.

### 7.4 Temporal indexes

Validity lookup MAY use range indexes, interval trees, or compiled epoch
bitmaps. Such indexes are derived views and MUST be invalidated or rebuilt when
their source version changes.

## 8. Cross-language boundary contract

Every Elixir/Gleam/Rust boundary SHALL have:

- a versioned input schema;
- a versioned output schema;
- explicit error variants;
- canonical golden vectors;
- differential tests against a reference implementation or fixture set;
- no hidden reads of process state, environment, time, database, or network
  unless the boundary explicitly declares those as inputs.

### 8.1 No duplicated policy

Two languages SHALL NOT independently encode the same normative rule unless
there is no practical shared implementation.

If duplication is unavoidable:

- one representation SHALL be declared authoritative;
- both implementations SHALL consume the same conformance vectors;
- CI SHALL run cross-language differential tests.

The existing SOP-versioning hazard documented in
`docs/sop-versioning.md` is the model of what this rule is intended to avoid.

## 9. Repository layout

The target layout MAY evolve toward:

```text
lib/spruce_goose/
  kernel/                 # Elixir/Ash ports, persistence shell, adapters
  ...

kernel_gleam/
  gleam.toml
  src/
    fsm/
    semantics/
    epistemics/
    authority/
    deontics/
    temporality/

native/
  kernel_native/
    Cargo.toml
    src/
      bitmap.rs
      ontology.rs
      automata.rs
      canonical.rs

priv/kernel/
  machines/               # reviewed machine definitions
  vectors/                # canonical cross-language vectors
  schemas/                # versioned boundary schemas

bench/
  kernel/                  # reproducible promotion benchmarks
```

The exact directory names are not operative until implemented. The ownership
classes are.

## 10. CI and review gates

A PR that changes only Elixir/Ash follows the normal repository gates.

A PR that changes Gleam SHALL additionally prove:

- Gleam formatting and compilation;
- exhaustive unit tests for new variants;
- Elixir/Gleam boundary tests;
- replay determinism for affected pure functions;
- no I/O or environment reads in the constitutional library.

A PR that changes Rust SHALL additionally prove:

- `cargo fmt --check`;
- `cargo clippy` with warnings denied;
- Rust unit tests;
- Elixir/Rust boundary tests;
- panic-free handling for untrusted boundary inputs;
- scheduler-safety classification for every NIF;
- benchmark evidence when the change is a performance promotion;
- semantic differential tests against the previous implementation.

A PR that changes a compiled representation SHALL prove rebuild equivalence:

```text
authoritative inputs
   -> compile
   -> snapshot A

same authoritative inputs
   -> clean rebuild
   -> snapshot B

semantic(A) == semantic(B)
```

Byte identity is preferred where the snapshot format promises determinism.

## 11. Review ownership

Every cross-language kernel PR SHOULD receive review from:

- one steward of the constitutional semantics;
- one steward of Ash/persistence/effect boundaries;
- for Rust, one reviewer competent in unsafe/native/scheduler implications.

No reviewer may waive an authority boundary merely because tests pass.

## 12. Change classification

### Class A — representation-preserving

Examples:

- replace Elixir bitmap intersection with Rust;
- add a compiled ontology cache;
- move a pure total transition function from Elixir to Gleam without changing
  accepted or refused cases.

Required: differential tests and rebuild proof.

### Class B — semantic

Examples:

- add a modality;
- change conflict resolution;
- change delegation semantics;
- change a state-machine transition;
- alter ontology mapping meaning.

Required: constitutional/spec review in addition to implementation review.

Performance evidence does not downgrade Class B to Class A.

### Class C — authority or effect boundary

Examples:

- move durable state ownership;
- change who can authorize;
- change the point at which an effect becomes executable;
- allow native code to persist or execute directly.

These are architecture/authority changes and require a separate explicit
decision. They SHALL NOT arrive disguised as refactoring.

## 13. Migration order

The preferred introduction order is:

```text
Phase 1
Elixir/Ash remains authoritative
Gleam introduced for one pure FSM or algebra

Phase 2
canonical vectors + cross-language differential harness

Phase 3
Rust introduced for canonicalization/crypto/bitsets only if justified

Phase 4
compiled ontology and candidate indexes

Phase 5
bulk replay/compiler only if measured need exists
```

Do not introduce all three languages into one new vertical slice unless the
slice independently needs each boundary.

## 14. Initial vertical slice

The first Gleam slice SHOULD be one machine whose current semantics can be
fully enumerated and tested without database access.

The first Rust slice SHOULD be one bounded primitive with:

- an existing reference implementation;
- canonical vectors;
- measurable cost;
- no durable writes;
- no authority decision.

Good candidates are ontology bitset membership/intersection or canonical
structural hashing.

The initial slice SHALL NOT move effect execution or durable state out of
Elixir/Ash.

## 15. Stewardship anti-patterns

The following require review rejection unless separately decided:

- Rust types becoming database identities;
- process-local ordinals written as constitutional identities;
- NIFs performing database or network I/O;
- Gleam code reading application environment to decide constitutional logic;
- Ash callbacks duplicating Gleam transition legality;
- Rust reimplementing deontic policy for speed;
- generated snapshots being treated as source artifacts;
- a benchmark generated from synthetic inputs with no representative workload;
- a language migration that changes accepted/refused cases without being
  classified as semantic;
- a native crash path that can leave an external effect without a recorded
  intent or terminal receipt.

## 16. Acceptance checklist

Before a language-boundary PR is accepted, reviewers SHALL be able to answer:

1. What is authoritative?
2. What is derived?
3. Which language owns the semantics?
4. Which language owns persistence?
5. Which language owns the optimized representation?
6. Can the optimized state be deleted and rebuilt?
7. Are stable identities preserved across the boundary?
8. Are all external observations explicit inputs?
9. Are errors typed and fail-closed?
10. Are accepted/refused cases covered by common vectors?
11. Does historical replay remain valid?
12. Does any protected effect remain behind durable authorization and intent?
13. If Rust is added, where is the profile or other promotion justification?
14. If semantics changed, where is the explicit semantic decision?

If any answer is unclear, the boundary is not ready.

## 17. Relationship to current SpruceGoose state

This document does not assert that the current `Kernel.Constitution` is a
Gleam candidate merely because it is pure. The current-state and D-4 findings
still apply: a function that validates caller-supplied answers does not become
a derivation engine by moving languages.

A Gleam migration is justified only after the constitutional question being
computed is explicit and the function actually derives its answer from
identified inputs.

Likewise, the current EventLedger, Ash resources, projector, and bounded effect
executor remain Elixir/Ash responsibilities unless a separately reviewed
authority-boundary decision says otherwise.

## 18. Repository authority

This document is a stewardship proposal on the GitHub mirror. It SHALL NOT be
treated as canonical merely because it exists in a GitHub branch or pull
request.

The canonical repository and merge/CI authority rules documented for
SpruceGoose remain unchanged. Any adopted version must be reconciled onto the
canonical head and pass the canonical verification gates before it can govern
implementation.

## 19. Summary rule

```text
Elixir/Ash:
  durable state · transactions · supervision · effects

Gleam:
  total typed transition and constitutional functions

Rust:
  rebuildable compiled data structures and bounded primitives
```

The repository SHALL optimize **below** the constitutional semantics, not
replace those semantics with opaque optimized code.
