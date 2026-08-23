#!/usr/bin/env python3
"""SPEC_deontic_core — executable formal model, exhaustively verified.

The five deontic values (H) are DERIVED, not postulated, from a three-axis
decomposition; H embeds in an aggregation monoid M whose fold is associative
(the naive 5-valued combination is not — L7c documents the counterexample);
resolution `resolve` maps folded state back to H or to conflict
(-> unresolved_conflict, fail closed).

Finite domain => every law below is checked by total enumeration.
Exit 0 iff all laws hold. Stdlib only. Deterministic.

Vocabulary note: this model is stated in neutral deontic-logic terms because
it is applied to isomorphisms internal to this system. Structural coincidence
with any external normative tradition is a remark, not a claim.
"""
from itertools import product

# ---- Derivation: three axes -> exactly five inhabitants -----------------
# A1 mode: Demand | Option; A2 direction (Demand only): Act | Refrain;
# A3 bindingness (Demand only): Binding | NonBinding.
AXES = [("Demand", d, b) for d in ("Act", "Refrain") for b in (True, False)] + [("Option",)]
NAME = {("Demand", "Act", True): "required", ("Demand", "Act", False): "encouraged",
        ("Demand", "Refrain", True): "forbidden", ("Demand", "Refrain", False): "discouraged",
        ("Option",): "neutral"}
H = tuple(NAME[a] for a in AXES)  # the five deontic values

# ---- Valence chain and involution --------------------------------------
V = {"forbidden": 0.0, "discouraged": 0.25, "neutral": 0.5,
     "encouraged": 0.75, "required": 1.0}
DUAL = {"required": "forbidden", "encouraged": "discouraged", "neutral": "neutral",
        "discouraged": "encouraged", "forbidden": "required"}  # act-negation transfer

# ---- Aggregation monoid M = ({0,1,2}^2, coordinatewise max) ------------
# state (c, o): strongest claim toward commission / omission seen so far.
E = {"required": (2, 0), "encouraged": (1, 0), "neutral": (0, 0),
     "discouraged": (0, 1), "forbidden": (0, 2)}  # embedding e : H -> M
M = list(product(range(3), repeat=2))

def fold(x, y):  # associative by construction
    return (max(x[0], y[0]), max(x[1], y[1]))

def resolve(s):  # resolution M -> H | CONFLICT
    c, o = s
    if c == 2 and o == 2: return "CONFLICT"   # opposed binding demands
    if c == 2: return "required"              # binding beats non-binding
    if o == 2: return "forbidden"
    if c == 1 and o == 1: return "neutral"    # tie -> neutral, gate-annotated
    if c == 1: return "encouraged"
    if o == 1: return "discouraged"
    return "neutral"

def combine(hs):  # multiset combination on H
    s = (0, 0)
    for h in hs: s = fold(s, E[h])
    return resolve(s)

# ---- compile : Tier x Polarity -> H (from the objectives overlay) ------
COMPILE = {("critical", "promote"): "required", ("critical", "prevent"): "forbidden",
           ("important", "promote"): "encouraged", ("important", "prevent"): "discouraged",
           ("refining", "promote"): "encouraged", ("refining", "prevent"): "discouraged"}
TIER_RANK = {"critical": 2, "important": 1, "refining": 0}

# ---- Authorization semantics -------------------------------------------
def may_authorize(h):  # A6 / prohibition-default handled upstream
    return h in {"required", "encouraged", "neutral"}

# ======================= exhaustive verification =========================
checks = []
def law(name, ok, note=""):
    checks.append((name, ok, note))
    print(f"{'PASS' if ok else 'FAIL'} {name}" + (f" — {note}" if note else ""))

law("L1 derivation exact", len(AXES) == 5 and set(H) == set(V) and len(set(H)) == 5,
    "three axes yield exactly five deontic values, bijectively")
law("L2 valence chain total order", sorted(V.values()) == [0.0, .25, .5, .75, 1.0])
law("L3 dual involution", all(DUAL[DUAL[h]] == h for h in H))
law("L4 dual antitone", all((V[a] <= V[b]) == (V[DUAL[b]] <= V[DUAL[a]]) for a in H for b in H))
law("L5 fix(dual) = {neutral}", [h for h in H if DUAL[h] == h] == ["neutral"])
law("L6 Lukasiewicz-5 iso", all(abs(V[DUAL[h]] - (1 - V[h])) < 1e-12 for h in H),
    "v(dual x) = 1 - v(x): (H, chain, dual) ~ L5 De Morgan chain")
law("L7a fold assoc+comm+idem on M", all(fold(fold(a,b),c) == fold(a,fold(b,c))
    for a in M for b in M for c in M) and all(fold(a,b) == fold(b,a) for a in M for b in M)
    and all(fold(a,a) == a for a in M))
law("L7b resolve . e = id", all(resolve(E[h]) == h for h in H),
    "embedding is resolution-faithful")
law("L7c naive 5-valued combine non-assoc witness",
    combine(["encouraged", "encouraged", "discouraged"]) == "neutral" and
    resolve(fold(E["encouraged"], E[resolve(fold(E["encouraged"], E["discouraged"]))])) == "encouraged",
    "hence aggregate in M, resolve once — order-independence restored")
law("L7d combine order-independent", all(
    combine(p) == combine(list(reversed(p)))
    for p in product(H, repeat=3)), "checked over all 125 triples")
law("L7e conflict iff binding-vs-binding", all(
    (combine(list(p)) == "CONFLICT") == ({"required", "forbidden"} <= set(p))
    for p in product(H, repeat=3)), "conflict exactly when binding demands oppose")
law("L8 identity neutral", all(combine([h, "neutral"]) == h for h in H))
law("L9 compile-polarity duality", all(COMPILE[(t, "promote")] == DUAL[COMPILE[(t, "prevent")]]
    for t in TIER_RANK), "polarity commutes with dual: promote/prevent land on dual values")
law("L10 compile monotone strength", all(
    abs(V[COMPILE[(t, d)]] - .5) <= abs(V[COMPILE[(u, d)]] - .5)
    for d in ("promote", "prevent") for t in TIER_RANK for u in TIER_RANK
    if TIER_RANK[t] <= TIER_RANK[u]), "higher tier => stronger (farther from neutral)")
law("L11 authorization sound",
    not may_authorize("forbidden") and not may_authorize("CONFLICT")
    and all(may_authorize(h) == (V[h] >= 0.5) for h in H),
    "forbidden and unresolved conflict never authorize; discouraged gates, not blocks")

# ---- Means transfer (audit F-6): two regimes ---------------------------
# T_NEC: necessary/determinate means -> full inheritance (identity).
#        Blocking transfer at full strength.
# T_AUX: auxiliary/non-determinate means -> symmetric attenuation: one strict
#        step toward neutral on the binding poles. Non-identity, so
#        dual-naturality below has content: a corrupted DUAL now fails L12.
T_NEC = {h: h for h in H}
T_AUX = {"required": "encouraged", "encouraged": "encouraged", "neutral": "neutral",
         "discouraged": "discouraged", "forbidden": "discouraged"}

law("L12 T dual-natural (both regimes)", all(
    Tm[DUAL[h]] == DUAL[Tm[h]] for Tm in (T_NEC, T_AUX) for h in H),
    "transfer commutes with act-negation; T_AUX != id gives the law force")
law("L12b blocking transfer (graded)",
    T_NEC["forbidden"] == "forbidden" and T_AUX["forbidden"] == "discouraged"
    and not may_authorize(T_NEC["forbidden"]) and not may_authorize(T_AUX["forbidden"]),
    "determinate means to a forbidden end is forbidden; auxiliary means is discouraged — neither authorizes")
law("L12c means never outrank ends, strictly attenuated when auxiliary", all(
    abs(V[Tm[h]] - .5) <= abs(V[h] - .5) for Tm in (T_NEC, T_AUX) for h in H)
    and abs(V[T_AUX["required"]] - .5) < abs(V["required"] - .5)
    and abs(V[T_AUX["forbidden"]] - .5) < abs(V["forbidden"] - .5),
    "no-strengthening for both; T_AUX strictly weakens the binding poles")

if all(ok for _, ok, _ in checks):
    print(f"\nRESULT: all {len(checks)} laws hold by total enumeration over |H|=5, |M|=9.")
    raise SystemExit(0)
print("\nRESULT: FAILURE — model refuted; spec must not be graded CANDIDATE.")
raise SystemExit(1)
