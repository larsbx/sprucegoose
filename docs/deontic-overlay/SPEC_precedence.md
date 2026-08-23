# SPEC_precedence v0.3 — Derivation of the Residual Gaps

**Status: DRAFT** · closes §9 of `SPEC_deontic_core`
**Certificates:** `precedence.py` (12 laws) and `deontic.exs` (20 laws, BEAM embodiment) — all verified by **total enumeration**: 96 norms × 96 × 3 acts = 27,648 conflict triples, 9³ fold triples, agreement across both embodiments.

> **Vocabulary note (v0.3).** As with the core spec, the domain-specific juristic vocabulary of earlier revisions is removed. These abstractions apply to isomorphisms internal to this system; borrowed terminology asserted a correspondence that was not being claimed. The mathematics is unchanged.

---

## Gap 1 — The precedence calculus, derived

A conflict is a folded state (2,2): opposed binding demands on one act. The natural resolution order is a **lexical ladder of partial orders** — the objectives lexicality law recurring at the meta-level:

**Rung 1 — harmonize via specificity.** Norms carry ontology-typed scopes. Under strict nesting S₁ ⊊ S₂, the specific norm prevails *inside* its scope and the general norm operates unopposed *outside* it — a partition, not a discard (T5: every act receives exactly one operative ruling). Equal or incomparable scopes pass to the next rung.

**Rung 2 — supersession by epoch.** The later norm prevails. Derived identification (T6): supersession **is** the kernel's grant/revocation-epoch ordering (A3/G5) — it needs no new primitive; the constitution already contains it.

**Rung 3 — evidence preponderance.** Grade g = (provenance, interpretation) ∈ {certain, probable}², ordered pointwise. (certain, probable) and (probable, certain) are left **incomparable** — the trade-off between source certainty and reading certainty stays open in the order rather than being silently legislated.

**Exhaustion → refuse.** No rung decides ⇒ `unresolved_conflict`, characterized exactly (T4): refusal occurs iff scopes don't strictly nest at the act, epochs tie, and grades are equal or incomparable. Fail closed — the ladder never manufactures a winner.

Laws: totality (T1), duality R(n₁,n₂) ↔ R(n₂,n₁) (T2), and **rung lexicality** (T3): a rung-1 decision is invariant under *all* variation of epoch and evidence — overwhelming strength at a lower rung cannot compensate. No cross-rung trade, ever.

## Gap 3 — The weight schema, derived

Five deontic values cannot separate three tiers × two poles. The missing coordinate is already present: **the precedence weight is the tier rank**, w ∈ {0,1,2}. Claims extend from strength s to lex-ordered pairs (s, w):

- Fold stays associative, commutative, idempotent — lex-max on totally ordered pairs (T7), so order-independence survives the extension.
- The (1,1) opposed-non-binding tie is now weight-broken: `important` outweighs `refining`; equal weight still resolves neutral and gate-annotated (T8).
- `compile' : Tier × Polarity → (value, w)` is **injective** — all six cells separated (T9) — and weight is monotone in tier (T10), carrying lexicality into the new coordinate.
- `compile'` preserves the duality law: same weight, dual value per tier (L9, both embodiments).

Canonical encoding for the joint oracle run: each norm row carries `{value, weight, guards, scope, epoch, grade}` — weight consumed at `resolve'`, the rest consumed at the ladder. One artifact, both overlays gradable in a single pass.

## Gap 2 — The keel embodiment

`deontic.exs`: the full model in Elixir — pattern-matched total functions, immutable throughout, zero dependencies, runs on OTP 24+. It re-verifies the core (derivation, De Morgan/Ł₅ chain, fold/resolve, `compile` duality, authorization soundness) plus the precedence and weighted-`compile` laws, and its verdict agrees with the Python certificate over the identical finite models. Drop-in path: the `Deontic` module's functions are the reference semantics for the kernel's `Norm`/`Resolution` slice; the enumeration block becomes its ExUnit suite verbatim. The Lean 4 port remains open but is now a translation task, not a design task — every definition is first-order over finite types.

## What this leaves genuinely open

1. **Scope decidability in the wild** — rung 1 assumes ontology-typed scopes with decidable strict inclusion; free-form scopes reduce to the gate. In practice this is where most real conflicts land, so the ladder's most elegant rung may fire less often than its prominence suggests.
2. **Grade assignment** — who certifies (provenance, interpretation) for a machine norm is an evidence-policy-root question, not an algebra question.
3. **Adoption** — as ever: both certificates and this document are DRAFT, bind by exact bytes, and cross the same external boundary as everything upstream.

---

## Changelog

**v0.2 (2026-08-23)** — amendment by replacement per audit F-1: v0.1's weighted-resolution conflict branch was correct but unverified — one law (T8) exercised only strength-1 states, so a CONFLICT→required regression would have shipped green. Added T11 (weighted resolution pinned against an independent reference over all 81 (strength, weight)² states) and T12 (conflict refuses for every weight pair — weight can never break a binding conflict; only the ladder may). The same hole existed in the BEAM embodiment and is closed there identically. Audit F-3 acknowledged as an equivalent mutant: pointwise and sum orderings coincide extensionally on {0,1}² — its survival is correct, not a gap.

**v0.3 (2026-08-23)** — **terminology revision, no change to the mathematics.** Juristic vocabulary replaced with neutral terms throughout: the ladder is `precedence`; its rungs are `specificity`, `supersession`, and `evidence strength`; grade axes are `provenance`/`interpretation` over `certain`/`probable`; tiers are `critical`/`important`/`refining`; poles are `promote`/`prevent`. Law count unchanged at 12; certificate re-verified as `precedence.py`. Prior identities are superseded, not rewritten.
