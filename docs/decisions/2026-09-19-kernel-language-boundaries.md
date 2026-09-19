# Kernel language boundaries — 2026-09-19

Status: **proposed, awaiting owner sign-off**

This decision records the implementation-language boundary proposed in
[`kernel-language-stewardship.md`](../kernel-language-stewardship.md).

## Question

How should SpruceGoose divide the abstract kernel across Elixir/Ash, Gleam, and
Rust without creating competing sources of authority or allowing performance
optimizations to obscure constitutional semantics?

## Proposed decision

Adopt the following ownership split:

- **Elixir/Ash** owns durable application coordination: resources, persistence,
  transactions, supervision, effect orchestration, adapters, and operational
  state.
- **Gleam** owns pure typed constitutional logic where finite variants,
  exhaustive pattern matching, and deterministic replay materially improve
  correctness: FSM transition legality, semantic IR, epistemic/deontic
  algebra, authority algebra, and temporal evaluation.
- **Rust** owns only narrow bounded primitives and rebuildable compiled
  representations: bitsets, ontology closure, intern tables, compiled automata,
  hashing/crypto, and optional bulk replay acceleration.

Stable constitutional identities remain outside compiled ordinals and native
memory representations. Rust caches and snapshots are derived state.

## Why

The split matches the existing repository boundary:

1. Ash/PostgreSQL already owns durable operational state and the current
   effect/persistence boundary.
2. The abstract-kernel remediation requires independently answerable,
   replayable constitutional questions rather than more caller-supplied flags.
3. Gleam can add compile-time exhaustiveness without replacing BEAM
   supervision or Ash persistence.
4. Rust is most valuable beneath the semantics, where dense bitsets, graph
   closure, hashing, canonical bytes, and compiled transition tables benefit
   from native layout and throughput.
5. Keeping native structures rebuildable prevents optimization artifacts from
   becoming a second constitutional authority.

## Rejected

### All-Elixir forever

Rejected as a policy. Elixir remains the default and may remain sufficient, but
the repository should have a governed route to stronger closed algebra and
native compiled structures where they materially improve correctness or
measured performance.

### Entire kernel in Rust

Rejected. It would move review pressure from constitutional exhaustiveness
toward low-level implementation detail, complicate scheduler/failure boundaries,
and risk turning native representations into authority.

### Entire kernel in Gleam

Rejected. Persistence, Ash policies/resources, OTP supervision, effects, and
integration boundaries already belong naturally to the Elixir/Ash application.

### Rust by intuition

Rejected. New native performance work requires profile/benchmark evidence or a
specific byte-exact/cryptographic/safety justification.

## Adoption effect

Adopting this decision does not itself:

- migrate code;
- change accepted/refused constitutional cases;
- move durable authority;
- alter the EventLedger;
- authorize effects;
- resolve D-2, D-3, or D-4 from the 2026-09-08 decision record.

Each implementation slice remains separately reviewable.

## First allowed slices

1. One pure finite-state or algebraic kernel function may move to Gleam with
   common conformance vectors and differential tests.
2. One bounded Rust primitive may be introduced only with a reference
   implementation, measured or primitive-specific justification, and no
   durable writes.
3. Elixir/Ash remains the durable owner throughout both slices.

## Canonicalization boundary

This proposal may be merged on the GitHub mirror into a non-`main` branch for
review, integration, or handoff. Such a merge is explicitly non-canonical and
does not transfer repository or production authority.

Mirror-side merge into GitHub `main` is not the adoption path. Repository
authority is acquired only after reconciliation onto the canonical repository
head and passage of the canonical CI/review gates.
