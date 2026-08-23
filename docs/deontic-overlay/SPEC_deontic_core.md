# SPEC_deontic_core v0.4 — The Five-Fold Deontic Overlay

**Status: DRAFT** · concurrent normative overlay to the objectives department spec
**Executable model:** `deontic.py` — all 18 laws verified by **total enumeration** (|H| = 5, |M| = 9): finite domain, so this is full verification, not sampling.
**Binding path:** per the Admission Contract §3, this overlay's exact bytes content-address into the **norm root**; the objectives overlay binds the ontology root. The two run concurrently over the same eight-root envelope, bridged by the compilation law `compile` (§5). No bypass: same adoption and revocation rules as any candidate.

> **Vocabulary note (v0.4).** Earlier revisions stated this model in the technical vocabulary of a specific juristic tradition. That vocabulary has been removed. These abstractions are applied to isomorphisms **internal to this system**, so borrowed terminology asserted a correspondence that was not being claimed and was therefore inaccurate. The mathematics is unchanged — same finite models, same laws, same enumeration. Where the resulting structure coincides with an external normative tradition, that is a remark about lattice shape, not a warrant, a lineage claim, or an appeal to authority.

---

## 1. Derivation (the five are theorems, not axioms)

Partition the space of normative positions on a single act by three dependent axes:

```
A1 mode:        Demand | Option
A2 direction:   Act | Refrain          — Demand only
A3 bindingness: Binding | NonBinding   — Demand only
```

Enumerating the dependent product yields exactly five inhabitants (L1, bijective):

| (mode, direction, binding) | value | reading |
|---|---|---|
| (Demand, Act, Binding) | **required** | must do |
| (Demand, Act, NonBinding) | **encouraged** | should do |
| (Option) | **neutral** | free |
| (Demand, Refrain, NonBinding) | **discouraged** | should not |
| (Demand, Refrain, Binding) | **forbidden** | must not |

The three axes are a **definition**; the five-fold structure is a theorem about that definition. Nothing here is imported from outside the model.

## 2. Algebra: a Łukasiewicz-5 De Morgan chain

Valence `v` maps H onto {0, ¼, ½, ¾, 1} (forbidden → 0 … required → 1), a total order (L2). Act-negation transfers value via the involution `dual` (swap A2):

```
dual(required) = forbidden    dual(encouraged) = discouraged    dual(neutral) = neutral
```

Verified: `dual∘dual = id` (L3), `dual` order-reversing (L4), `fix(dual) = {neutral}` (L5), and `v(dual x) = 1 − v(x)` (L6) — so (H, ⊑, dual) **is** the five-valued Łukasiewicz De Morgan chain. This is the formal home of the objectives overlay's polarity duality: promote and prevent clauses land on dual values.

## 3. Aggregation: embed, fold, resolve once

Combining multiple rulings on one act naively over H is **not associative** — witness (L7c): `encouraged ⊕ (encouraged ⊕ discouraged) ≠ (encouraged ⊕ encouraged) ⊕ discouraged`. The repair is structural:

**Embed** H into M = ({0,1,2}², max × max), tracking the strongest claim toward commission and toward omission:

```
e(required)=(2,0)  e(encouraged)=(1,0)  e(neutral)=(0,0)  e(discouraged)=(0,1)  e(forbidden)=(0,2)
```

**Fold** in M — coordinatewise max is associative, commutative, idempotent by construction (L7a), so aggregation is order-independent over any multiset of norms (L7d, all 125 triples).

**Resolve** once via `resolve : M → H ∪ {conflict}`:

| folded state | resolution | rationale |
|---|---|---|
| (2,2) | **conflict** → refuse `unresolved_conflict` | binding demands oppose; only precedence metadata (specificity, later epoch, evidence strength) may break it — never a default |
| (2,·) / (·,2) | required / forbidden | a binding claim absorbs a non-binding one |
| (1,1) | neutral, gate-annotated | opposed non-binding claims: neutral for authorization, recorded for precedence review |
| (1,0) / (0,1) | encouraged / discouraged | |
| (0,0) | neutral | identity (L8) |

`resolve∘e = id` (L7b), and conflict arises **exactly** when required and forbidden co-occur (L7e) — the algebra locates conflict precisely where the contract's A5 expects it.

## 4. The declaratory layer as guards

Declaratory conditions gate applicability: **trigger** (the condition that activates the norm), **precondition** (what must hold), **blocker** (what defeats it):

```
applicable(norm, ctx) = trigger(ctx) ∧ precondition(ctx) ∧ ¬blocker(ctx)
```

Kernel mapping: guards are Propositions discharged by Evidence. Contested or absent evidence leaves a guard unknown → the norm does not enter the fold → and where its absence matters, refuse `contested_evidence`. Fail closed: no guard is presumed satisfied.

## 5. `compile` — compiling the objectives overlay into deontic values

The bridge between the concurrent overlays:

```
compile : Tier × Polarity → H
compile(critical,  promote) = required     compile(critical,  prevent) = forbidden
compile(important, promote) = encouraged   compile(important, prevent) = discouraged
compile(refining,  promote) = encouraged†  compile(refining,  prevent) = discouraged†
```

† `important` and `refining` share deontic values (five values cannot separate three tiers × strength); they are separated by **precedence weight**, an annotation consumed at resolution — never by inventing a sixth value.

Laws: **`compile` commutes with the dualities** — `compile(t, promote) = dual(compile(t, prevent))` for every tier (L9), i.e. polarity duality and `dual` are the same symmetry seen from the two overlays. And `compile` is **monotone in strength**: higher tier ⇒ farther from neutral (L10), which is the objectives lexicality law re-expressed in valence.

## 6. Means transfer and blocking

Means inherit the value of their ends. Two verified transfer regimes:

- **T_NEC** — necessary/determinate means: full inheritance. If the end cannot be achieved without this means, the means carries the end's value exactly. Blocking transfer at full strength.
- **T_AUX** — auxiliary/supporting means: symmetric attenuation, one strict step toward neutral on the binding poles.

So a determinate means to a forbidden end is **forbidden**, while a merely auxiliary one is **discouraged**; both are dual-natural, and neither authorizes (L12/L12b/L12c). The attenuation is what gives the laws force: because `T_AUX ≠ id`, dual-naturality is a real constraint rather than a tautology, and a corrupted `dual` table fails L12 directly.

## 7. Authorization semantics and the prohibition default

```
may_authorize(h) ⟺ v(h) ≥ ½    (required, encouraged, neutral)
```

`forbidden` and unresolved `conflict` never authorize; `discouraged` does not block but routes to the gate (L11).

One deliberate asymmetry: for **delegated machine effects** this spec adopts **prohibition by default** — an agent acts only under an explicit grant, and the contract's effect allowlist (A6, currently `verify_artifact` only) *is* that presumption implemented. An action absent from the allowlist is not neutral-by-silence; it refuses `unauthorized_effect`. This is a design choice about delegated capability, justified by the asymmetry between an autonomous actor and a delegated one — not an inherited doctrine.

## 8. Kernel binding

| Kernel primitive | Carries |
|---|---|
| Norm | (value h, guards {trigger, precondition, blocker}, precedence weight) — compatible with the ontology version (R4) |
| Resolution | fold-in-M + `resolve` + precedence ladder; (2,2) without dominating precedence ⇒ `unresolved_conflict` |
| Authorization | only from resolved h with v ≥ ½, and never without the constitutional Grant — the deontic value licenses, the grant authorizes; neither substitutes for the other (A1–A4 untouched) |
| EffectIntent | inert regardless of deontic value (A7) |

Lifecycle, adoption, and refusal discipline are inherited unchanged from the Admission Contract: this overlay is DRAFT, cannot self-adopt, and binds by exact bytes into the norm root at admission.

## 9. Residual gaps

1. **Precedence calculus** — formalized in the companion `SPEC_precedence`; the (2,2) breaker is derived there as a lexical ladder.
2. **Port to the keel** — the Python model is a finite-model certificate; the normative embodiment lives in `deontic.exs` (BEAM), with a Lean 4 port open but mechanical (|H| = 5, first-order over finite types).
3. **Weight schema** — the precedence-weight annotation separating `important`/`refining` needs a canonical encoding before the two overlays can be jointly graded by one oracle run.

---

## Changelog

**v0.2 (2026-08-23)** — amendment by replacement per audit: F-2 fixed — the v0.1 L12 was tautological (`X == X`); replaced with an explicit means-transfer map and three constrained laws (dual-naturality, blocking transfer, means-never-outrank-ends), each with a demonstrated failing mutant. v0.1 verified 15 substantive laws, not the 16 claimed; v0.2 verifies 18.

**v0.3 (2026-08-23)** — amendment by replacement per audit F-6: v0.2's transfer map was the identity, so L12/L12b/L12c constrained only transfer corruption while blind to any `dual` error — subtler than v0.1's tautology because it looked substantive. Fixed by deriving the two transfer regimes: T_NEC (identity, necessary means) and T_AUX (symmetric attenuation, auxiliary means). Audit F-5 fixed at bundle level: the manifest no longer lists itself.

**v0.4 (2026-08-23)** — **terminology revision, no change to the mathematics.** The domain-specific juristic vocabulary of v0.1–v0.3 is replaced throughout with neutral deontic-logic terms, because these abstractions are applied to isomorphisms internal to this system and the borrowed vocabulary asserted an inaccurate correspondence. Identifier map: the five values → `required`/`encouraged`/`neutral`/`discouraged`/`forbidden`; ν → `dual`; θ → `compile`; ρ → `resolve`; tiers → `critical`/`important`/`refining`; poles → `promote`/`prevent`; W_IND/W_SUP → `T_NEC`/`T_AUX`; conflict and the precedence ladder renamed correspondingly. Two substantive corrections accompany the rename: §1 no longer claims the five values are read off an external taxonomy (they are a theorem about a stated definition), and §7's prohibition default is now justified by the autonomous/delegated asymmetry rather than by doctrinal inheritance. Law count unchanged at 18; certificates re-verified (`deontic.py` 18, `precedence.py` 12, `deontic.exs` 20). Prior identities are superseded, not rewritten.
