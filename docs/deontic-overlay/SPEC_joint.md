# SPEC_joint v0.1 — The Canonical Norm Row and One-Pass Grading

**Status: DRAFT** · closes residual gap 3 of `SPEC_deontic_core` and gap 3 of `SPEC_precedence`
**Certificates:** `priv/deontic/joint.py` and `priv/deontic/joint.exs` — 13 laws each, both agreeing.

> **Vocabulary note.** Stated in neutral deontic-logic terms, consistent with `TERMS.md`. These abstractions apply to isomorphisms internal to this system.

---

## 1. The gap this closes

Five deontic values cannot separate three tiers × two poles, so `compile` maps
both `important` and `refining` onto the same pair of values. The separating
coordinate is the **precedence weight**, which equals the tier rank. Until now
that annotation had no canonical encoding, so the deontic overlay and the
precedence overlay had to be graded in two passes with no proof that the two
agreed.

## 2. The canonical norm row

```
(value, weight, guards, scope, epoch, grade)
```

| field | domain | consumed by |
|---|---|---|
| `value` | the five deontic values | fold |
| `weight` | tier rank {0,1,2} | weighted resolution |
| `guards` | (trigger, precondition, blocker), three-valued | admission filter |
| `scope` | ontology-typed act set | precedence rung 1 |
| `epoch` | supersession ordering | precedence rung 2 |
| `grade` | (provenance, interpretation) | precedence rung 3 |

One artifact, both overlays gradable in a single pass.

## 3. The pipeline

```
filter(guards) → fold(value, weight) → resolve → [ladder, only on conflict]
```

**Filter.** Guards are three-valued: discharged, refuted, or **unknown**. A norm
enters the fold only when the trigger and precondition are discharged *and* the
blocker is known absent. Unknown is not permission — J1 verifies that exactly
one of the 27 guard states admits a norm and that no state containing an unknown
ever admits. This is the declaratory layer of `SPEC_deontic_core` §4 made
executable, and it fails closed.

**Fold.** Each applicable row embeds to a pair of `(strength, weight)` claims,
folded by coordinatewise lex-max. Neutral makes no claim and therefore carries
no weight, which is what keeps it the fold identity regardless of the weight
written on the row (J4).

**Resolve.** Weighted resolution comes from the certified precedence overlay
unchanged.

**Ladder.** Only when resolution returns conflict. Every opposed binding pair is
put to the precedence ladder; if any pair is undecided, or if decided pairs
disagree, the whole set refuses.

## 4. The enumeration claim, stated honestly

The raw norm-row space is 5 × 3 × 27 × 8 × 3 × 4 = **38,880**. The pairwise
product is ≈1.5 × 10⁹ and the triple product ≈5.9 × 10¹³. **Those are not
enumerated**, and a bare claim of "verified by total enumeration" at this layer
would be a false proof.

Instead **J2** proves the pipeline reads guards only through the boolean
`applicable`: for every pair of guard states with equal applicability, and every
fold projection, the verdict is identical (20,310 substitutions). That
factorization licenses enumerating the projections, each of which **is**
enumerated totally:

| projection | size | law |
|---|---|---|
| guard states | 27 | J1 |
| fold projections `(applicable, value, weight)` | 30, triples 27,000 | J5, J6, J10 |
| ladder rows `(scope, epoch, grade)` | 96, × acts 27,648 | J9 |
| refusing ladder configurations | 1,404, × weights 12,636 | J12 |

The factorization is the load-bearing step. Without J2, every table below would
be sampling wearing the costume of a proof.

## 5. Agreement, not reimplementation

Both certificates **load the certified overlay sources as libraries** and call
them, splitting each file at its own verification banner so only definitions are
executed. The two overlays are never transcribed.

This matters because the cheapest wrong implementation of a joint pipeline is a
second copy of resolution and precedence that silently diverges. Here any drift
in `deontic.py`, `precedence.py`, or `deontic.exs` is inherited rather than
masked, and:

- **J8** checks the joint verdict equals the deontic overlay's `combine` across
  all 125 value triples minus the conflict cases;
- **J9** checks the joint verdict equals the precedence ladder's decision across
  all 27,648 conflict triples.

## 6. Invariants preserved through the join

- **J3** — weighted fold stays associative, commutative, idempotent.
- **J6** — order-independent over norm multisets.
- **J7** — inapplicable rows are inert: 13,500 cases, every fold pair against
  every inert row. Pairwise inertness lifts to any multiset by J3 associativity.
- **J10** — conflict arises exactly when opposed binding claims are *applicable*;
  guarded-out rows can neither manufacture nor suppress a conflict.
- **J11** — weight never breaks a conflict. With the ladder tied, no weight pair
  decides; only the ladder may.
- **J12** — authorization soundness survives: `forbidden` and every refusal never
  authorize, across all 12,636 refusal-and-weight combinations.

## 7. What this does not do

This schema grades. It does not adopt, and it confers no authority. A verdict of
`required` licenses nothing on its own — the constitutional Grant authorizes, and
neither substitutes for the other. `SpecAdopted` remains unimplemented, so this
document, like every deontic spec, is DRAFT and non-operative.

## 8. Residual gaps

1. **Guard evidence binding** — guards are modelled as three-valued propositions.
   Which Evidence discharges which Proposition, and who certifies it, is an
   evidence-policy-root question this schema deliberately does not answer.
2. **Scope decidability** — inherited from `SPEC_precedence`: rung 1 assumes
   ontology-typed scopes with decidable strict inclusion. Free-form scopes reduce
   to the gate.
3. **Adoption** — as ever, external.

---

## Changelog

**v0.1 (2026-08-23)** — closes gap 3. Defines the canonical norm row and the
one-pass pipeline, proves the guard factorization that makes projection
enumeration sound, and verifies agreement with both existing overlays rather
than reimplementing them. 13 laws in each embodiment.

An earlier draft of the certificate sampled two laws (`TRIPLES[::37]`,
`LADDER_ROWS[::13]`) while the result line claimed total enumeration. That is
exactly the false proof §4 warns about; both laws were replaced with total
enumeration over the licensed projections before publication.
