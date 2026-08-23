#!/usr/bin/env python3
"""SPEC_deontic_joint — the canonical norm row and one-pass joint grading.

Closes residual gap 3. The precedence weight had no canonical encoding, so the
deontic overlay and the precedence overlay could not be graded together in a
single oracle pass. A norm row is

    (value, weight, guards, scope, epoch, grade)

and the pipeline is

    filter(guards) -> fold(value, weight) -> resolve -> [ladder on conflict]

Weight is consumed at weighted resolution. Scope, epoch, and grade are consumed
only by the precedence ladder, and only when resolution returns conflict.

HONEST ENUMERATION CLAIM
------------------------
The raw row space is 5*3*27*8*3*4 = 38,880. The pairwise product is ~1.5e9 and
the triple product ~5.9e13. Those are NOT enumerated here, and a bare "verified
by total enumeration" would be a false proof at this layer.

Instead J2 proves the pipeline reads guards only through the boolean
`applicable`. That factorization licenses enumerating the projections, each of
which IS enumerated totally:

    guard space        (trigger, precondition, blocker)  27, pairs 729
    fold projection    (applicable, value, weight)       30, triples 27,000
    ladder projection  (scope, epoch, grade)             96, pairs x acts 27,648

The two overlays are not reimplemented. Their certified sources are loaded as
libraries and called, so agreement is by construction and J6/J7 check the
wiring rather than a copy.

Exit 0 iff all laws hold. Stdlib only. Deterministic.
"""
import os
import sys
from itertools import product

HERE = os.path.dirname(os.path.abspath(__file__))
MARKER = "# ======================= exhaustive verification ========================="


def load(filename):
    """Load a certificate's definitions without running its verification block.

    The source is split at the certificate's own verification banner and only
    the definition half is executed. This uses the exact certified bytes rather
    than a transcription, so any drift in those files is inherited here instead
    of being silently masked by a second copy.
    """
    path = os.path.join(HERE, filename)
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    if MARKER not in source:
        raise SystemExit(f"FAIL: {filename} has no verification marker; refusing to guess")
    namespace = {"__name__": f"_lib_{filename}", "__file__": path}
    exec(compile(source.split(MARKER)[0], path, "exec"), namespace)  # noqa: S102
    return namespace


D = load("deontic.py")
P = load("precedence.py")

H = D["H"]
V = D["V"]
DUAL = D["DUAL"]
TIER_RANK = D["TIER_RANK"]
may_authorize = D["may_authorize"]
resolve_w = P["resolve_w"]
precedence = P["precedence"]
compile_w = P["compile_w"]
SCOPES, EPOCHS, GRADES, U = P["SCOPES"], P["EPOCHS"], P["GRADES"], P["U"]

# ---- The canonical norm row --------------------------------------------
# guards: three-valued. True = discharged, False = refuted, None = unknown.
TRI = (True, False, None)
GUARDS = tuple(product(TRI, repeat=3))          # (trigger, precondition, blocker)
LADDER_ROWS = [(s, e, g) for s in SCOPES for e in EPOCHS for g in GRADES]
WEIGHTS = (0, 1, 2)


def applicable(guards):
    """Fail closed: a norm enters the fold only on discharged evidence.

    Unknown is not permission. The blocker must be known absent, not merely
    unproven, so an unknown blocker keeps the norm out of the fold.
    """
    trigger, precondition, blocker = guards
    return trigger is True and precondition is True and blocker is False


def embed(value, weight):
    """Row -> (commission claim, omission claim) as (strength, weight) pairs.

    Neutral makes no claim, so it carries no weight; that is what keeps it the
    fold identity regardless of the weight written on the row.
    """
    if value == "required":
        return (2, weight), (0, 0)
    if value == "encouraged":
        return (1, weight), (0, 0)
    if value == "discouraged":
        return (0, 0), (1, weight)
    if value == "forbidden":
        return (0, 0), (2, weight)
    return (0, 0), (0, 0)


def lexmax(x, y):
    return x if x >= y else y


def fold_state(rows):
    """Fold the applicable rows. Lex-max on (strength, weight), coordinatewise."""
    commission, omission = (0, 0), (0, 0)
    for row in rows:
        if not applicable(row["guards"]):
            continue
        claim_c, claim_o = embed(row["value"], row["weight"])
        commission = lexmax(commission, claim_c)
        omission = lexmax(omission, claim_o)
    return commission, omission


def ladder_of(row):
    return (row["scope"], row["epoch"], row["grade"])


def joint(rows, act):
    """One pass over a norm multiset: filter, fold, resolve, then ladder."""
    live = [row for row in rows if applicable(row["guards"])]
    commission, omission = fold_state(live)
    base = resolve_w(commission, omission)
    if base != "CONFLICT":
        return base
    commits = [r for r in live if r["value"] == "required"]
    omits = [r for r in live if r["value"] == "forbidden"]
    verdicts = set()
    for winner in commits:
        for loser in omits:
            decision = precedence(ladder_of(winner), ladder_of(loser), act)
            if decision == 0:
                return "REFUSE"          # any undecided pair refuses the whole set
            verdicts.add("required" if decision == 1 else "forbidden")
    if len(verdicts) != 1:
        return "REFUSE"                  # opposed pairs disagreeing refuses
    return verdicts.pop()


def row(value, weight=0, guards=(True, True, False),
        scope=frozenset("abc"), epoch=0, grade=(0, 0)):
    return {"value": value, "weight": weight, "guards": guards,
            "scope": scope, "epoch": epoch, "grade": grade}


def authorized(rows, act):
    """Authorization through the joint pipeline. Refusal never authorizes."""
    verdict = joint(rows, act)
    return verdict in {"required", "encouraged", "neutral", "neutral_gated"}


# ======================= exhaustive verification =========================
checks = []


def law(name, ok, note=""):
    checks.append((name, ok, note))
    print(f"{'PASS' if ok else 'FAIL'} {name}" + (f" — {note}" if note else ""))


law("J0 certificates loaded, not transcribed",
    callable(resolve_w) and callable(precedence) and set(H) == set(V) and len(H) == 5,
    "deontic.py and precedence.py supply the semantics used below")

# --- guard layer: 27 states, enumerated totally -------------------------
law("J1 guards fail closed",
    all(applicable(g) == (g == (True, True, False)) for g in GUARDS)
    and not any(applicable(g) for g in GUARDS if None in g),
    f"exactly 1 of {len(GUARDS)} guard states admits a norm; unknown never admits")

# --- the factorization that licenses every enumeration below ------------
FOLD_PROJ = [(a, v, w) for a in (True, False) for v in H for w in WEIGHTS]


def as_row(proj, ladder=(frozenset("abc"), 0, (0, 0))):
    a, v, w = proj
    guards = (True, True, False) if a else (True, True, True)
    return {"value": v, "weight": w, "guards": guards,
            "scope": ladder[0], "epoch": ladder[1], "grade": ladder[2]}


law("J2 guards enter only through applicable", all(
    joint([{**as_row(proj), "guards": g1}], "a")
    == joint([{**as_row(proj), "guards": g2}], "a")
    for g1 in GUARDS for g2 in GUARDS if applicable(g1) == applicable(g2)
    for proj in FOLD_PROJ),
    f"{sum(1 for g1 in GUARDS for g2 in GUARDS if applicable(g1) == applicable(g2)) * len(FOLD_PROJ)} "
    "substitutions; this is what makes projection enumeration sound rather than sampling")

# --- fold layer: 30 projections, all triples ----------------------------
CLAIMS = [(s, w) for s in range(3) for w in range(3)]
law("J3 weighted fold assoc+comm+idem",
    all(lexmax(lexmax(x, y), z) == lexmax(x, lexmax(y, z))
        for x in CLAIMS for y in CLAIMS for z in CLAIMS)
    and all(lexmax(x, y) == lexmax(y, x) for x in CLAIMS for y in CLAIMS)
    and all(lexmax(x, x) == x for x in CLAIMS),
    "lex-max on (strength, weight) keeps the monoid laws after the extension")

law("J4 neutral is the fold identity at every weight", all(
    fold_state([row(v, w), row("neutral", nw)]) == fold_state([row(v, w)])
    for v in H for w in WEIGHTS for nw in WEIGHTS),
    "a neutral row carries no claim, so its weight cannot leak into the state")

TRIPLES = list(product(FOLD_PROJ, repeat=3))
law("J5 joint total over all fold-projection triples", all(
    joint([as_row(p) for p in triple], "a")
    in {"required", "encouraged", "neutral", "neutral_gated",
        "discouraged", "forbidden", "REFUSE"}
    for triple in TRIPLES),
    f"{len(TRIPLES)} triples, every result in the declared codomain")

law("J6 order-independent over norm multisets", all(
    joint([as_row(p) for p in triple], "a")
    == joint([as_row(p) for p in reversed(triple)], "a")
    for triple in TRIPLES),
    f"{len(TRIPLES)} triples reversed; folding is a multiset operation")

INERT = [(False, v, w) for v in H for w in WEIGHTS]
PAIRS = list(product(FOLD_PROJ, repeat=2))
law("J7 inapplicable rows are inert", all(
    joint([as_row(p) for p in pair] + [as_row(dead)], "a")
    == joint([as_row(p) for p in pair], "a")
    for pair in PAIRS for dead in INERT),
    f"{len(PAIRS) * len(INERT)} cases, every pair against every inert row; "
    "J3 associativity lifts pairwise inertness to any multiset")

# --- agreement with the separate overlays, not a reimplementation -------
combine = D["combine"]


def flatten(verdict):
    return "neutral" if verdict == "neutral_gated" else verdict


law("J8 agrees with the deontic overlay at equal weight", all(
    flatten(joint([row(v, 1) for v in values], "a")) == combine(list(values))
    for values in product(H, repeat=3)
    if not ({"required", "forbidden"} <= set(values))),
    "all 125 triples minus the conflict cases; weight ties collapse to neutral")

law("J9 agrees with the precedence ladder on conflict", all(
    joint([row("required", 1, scope=n1[0], epoch=n1[1], grade=n1[2]),
           row("forbidden", 1, scope=n2[0], epoch=n2[1], grade=n2[2])], act)
    == {0: "REFUSE", 1: "required", 2: "forbidden"}[precedence(n1, n2, act)]
    for n1 in LADDER_ROWS for n2 in LADDER_ROWS for act in U),
    f"{len(LADDER_ROWS) ** 2 * len(U)} conflict triples resolved by the ladder alone")

# --- the invariants that must survive the join --------------------------
law("J10 conflict iff opposed binding applicable claims", all(
    (resolve_w(*fold_state([as_row(p) for p in triple])) == "CONFLICT")
    == ({"required", "forbidden"}
        <= {v for a, v, _ in triple if a})
    for triple in TRIPLES),
    "guarded-out rows cannot manufacture or suppress a conflict")

law("J11 weight never breaks a conflict", all(
    joint([row("required", w1, epoch=e, grade=g),
           row("forbidden", w2, epoch=e, grade=g)], "a") == "REFUSE"
    for w1 in WEIGHTS for w2 in WEIGHTS
    for e in EPOCHS for g in GRADES),
    "with the ladder tied, no weight pair decides; only the ladder may")

REFUSING = [(n1, n2, act) for n1 in LADDER_ROWS for n2 in LADDER_ROWS
            for act in U if precedence(n1, n2, act) == 0]
law("J12 authorization sound through the joint pipeline",
    not authorized([row("forbidden", 2)], "a")
    and not authorized([row("required", 2), row("forbidden", 2)], "a")
    and all(authorized([row(v, w)], "a") == (V[v] >= 0.5)
            for v in H for w in WEIGHTS)
    and all(not authorized([row("required", w1, scope=n1[0], epoch=n1[1], grade=n1[2]),
                            row("forbidden", w2, scope=n2[0], epoch=n2[1], grade=n2[2])], act)
            for (n1, n2, act) in REFUSING
            for w1 in WEIGHTS for w2 in WEIGHTS),
    f"forbidden never authorizes; all {len(REFUSING) * len(WEIGHTS) ** 2} "
    "refusal-and-weight combinations never authorize; discouraged gates, not blocks")

if all(ok for _, ok, _ in checks):
    print(f"\nRESULT: all {len(checks)} laws hold by total enumeration over the "
          f"projections J2 licenses ({len(GUARDS)} guard states, "
          f"{len(FOLD_PROJ)} fold projections, {len(LADDER_ROWS)} ladder rows).")
    raise SystemExit(0)
print("\nRESULT: FAILURE — joint model refuted; the schema must not be graded CANDIDATE.")
raise SystemExit(1)
