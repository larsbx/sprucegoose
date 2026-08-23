#!/usr/bin/env python3
"""SPEC_precedence — derivation of the residual gaps, exhaustively verified.

Gap 1 (precedence calculus): the (2,2) conflict breaker derived as a LEXICAL
LADDER of partial orders — specificity, then supersession by epoch, then
evidence strength — refusing when all rungs exhaust. The lexicality law of
the objectives overlay recurs at the meta-level: no rung compensates across
rungs.

Gap 3 (compile weights): the precedence weight is the tier rank itself.
Extending the fold monoid from strength s in {0,1,2} to lex-ordered (s, w)
pairs keeps associativity and makes compile' injective — (value, weight)
separates what five deontic values alone cannot.

Finite models throughout => every law checked by total enumeration.
Exit 0 iff all laws hold. Stdlib only.
"""
from itertools import product

# ===================== Gap 1: precedence ladder ==========================
U = frozenset("abc")  # act universe (finite model)
SCOPES = [frozenset(s) for s in
          ("", "a", "b", "c", "ab", "ac", "bc", "abc")]
EPOCHS = (0, 1, 2)
# evidence grade (provenance, interpretation), certain=1 > probable=0;
# pointwise partial order, (1,0) and (0,1) deliberately incomparable —
# the trade-off between source certainty and reading certainty stays open.
GRADES = tuple(product((0, 1), repeat=2))
def grade_gt(g, h): return g != h and g[0] >= h[0] and g[1] >= h[1]

# a conflicting norm: (scope, epoch, grade); value fixed as opposed binding pair
NORMS = [(s, e, g) for s in SCOPES for e in EPOCHS for g in GRADES]

def rung1(n1, n2, act):  # harmonize via strict scope nesting
    s1, s2 = n1[0], n2[0]
    if s1 < s2: return 1 if act in s1 else 2  # specific prevails inside its scope
    if s2 < s1: return 2 if act in s2 else 1  # general unopposed outside it
    return 0  # equal or incomparable: pass

def rung2(n1, n2):  # supersession: later epoch
    return 1 if n1[1] > n2[1] else 2 if n2[1] > n1[1] else 0

def rung3(n1, n2):  # evidence preponderance
    return 1 if grade_gt(n1[2], n2[2]) else 2 if grade_gt(n2[2], n1[2]) else 0

def precedence(n1, n2, act):  # the lexical ladder
    for r in (rung1(n1, n2, act), rung2(n1, n2), rung3(n1, n2)):
        if r: return r
    return 0  # 0 = REFUSE unresolved_conflict

# ===================== Gap 3: weighted fold ==============================
# claim = (strength s in {0,1,2}, weight w in {0,1,2}=tier rank); lex max
def lmax(x, y): return x if x >= y else y
def wfold(a, b): return (lmax(a[0], b[0]), lmax(a[1], b[1]))

TIER_RANK = {"critical": 2, "important": 1, "refining": 0}
def compile_w(tier, pole):  # compile': Tier x Polarity -> (value, w)
    h = {("critical", "promote"): "required", ("critical", "prevent"): "forbidden",
         ("important", "promote"): "encouraged", ("important", "prevent"): "discouraged",
         ("refining", "promote"): "encouraged", ("refining", "prevent"): "discouraged"}[(tier, pole)]
    return (h, TIER_RANK[tier])

def resolve_w(c, o):  # weighted resolution
    (cs, cw), (os_, ow) = c, o
    if cs == 2 and os_ == 2: return "CONFLICT"  # -> precedence ladder above
    if cs == 2: return "required"
    if os_ == 2: return "forbidden"
    if cs == 1 and os_ == 1:  # the (1,1) tie, now weight-broken
        return "encouraged" if cw > ow else "discouraged" if ow > cw else "neutral_gated"
    if cs == 1: return "encouraged"
    if os_ == 1: return "discouraged"
    return "neutral"

# ======================= exhaustive verification =========================
checks = []
def law(name, ok, note=""):
    checks.append((name, ok))
    print(f"{'PASS' if ok else 'FAIL'} {name}" + (f" — {note}" if note else ""))

pairs_acts = [(n1, n2, a) for n1 in NORMS for n2 in NORMS for a in U]
law("T1 precedence total", all(precedence(*p) in (0, 1, 2) for p in pairs_acts),
    f"decision function total over {len(pairs_acts)} (norm,norm,act) triples")
law("T2 precedence dual", all(
    precedence(n1, n2, a) == {0: 0, 1: 2, 2: 1}[precedence(n2, n1, a)]
    for n1, n2, a in pairs_acts), "R(n1,n2) mirrors R(n2,n1) exactly")
law("T3 rung lexicality", all(
    precedence((n1[0], e1, g1), (n2[0], e2, g2), a) == precedence(n1, n2, a)
    for n1, n2, a in pairs_acts if rung1(n1, n2, a)
    for e1 in EPOCHS for e2 in EPOCHS for g1 in GRADES for g2 in GRADES),
    "a rung-1 decision is invariant under ALL epoch/evidence variation — no cross-rung compensation")
law("T4 refusal characterized", all(
    (precedence(n1, n2, a) == 0) ==
    (rung1(n1, n2, a) == 0 and n1[1] == n2[1]
     and not grade_gt(n1[2], n2[2]) and not grade_gt(n2[2], n1[2]))
    for n1, n2, a in pairs_acts),
    "REFUSE exactly when every rung ties or is incomparable — fail closed, never a default winner")
law("T5 specificity partition sound", all(
    all(precedence(n1, n2, a) == (1 if a in n1[0] else 2) for a in U)
    for n1 in NORMS for n2 in NORMS if n1[0] < n2[0]),
    "strict nesting: each act gets exactly one operative ruling — harmonization, not discard")
law("T6 epoch rung = kernel supersession", all(
    precedence(n1, n2, a) == (1 if n1[1] > n2[1] else 2)
    for n1, n2, a in pairs_acts
    if rung1(n1, n2, a) == 0 and n1[1] != n2[1]),
    "supersession is exactly grant/revocation-epoch ordering (A3/G5) — already a kernel concept")

CLAIMS = list(product(range(3), repeat=2))
law("T7 weighted fold assoc+comm+idem", all(
    wfold(wfold(x, y), z) == wfold(x, wfold(y, z))
    for x in CLAIMS for y in CLAIMS for z in CLAIMS)
    and all(wfold(x, y) == wfold(y, x) for x in CLAIMS for y in CLAIMS)
    and all(wfold(x, x) == x for x in CLAIMS),
    "lex-max on (strength, weight) — order-independence preserved after the extension")
law("T8 weight breaks (1,1) tie", all(
    resolve_w((1, w1), (1, w2)) ==
    ("encouraged" if w1 > w2 else "discouraged" if w2 > w1 else "neutral_gated")
    for w1 in range(3) for w2 in range(3)),
    "important outweighs refining at the tie; equal weight still gates")
law("T9 compile' injective", len({compile_w(t, p) for t in TIER_RANK
    for p in ("promote", "prevent")}) == 6,
    "(value, weight) separates all six Tier x Polarity cells — the gap five values could not close")
law("T10 weight monotone in tier", all(
    compile_w(t, p)[1] >= compile_w(u, p)[1]
    for p in ("promote", "prevent") for t in TIER_RANK for u in TIER_RANK
    if TIER_RANK[t] >= TIER_RANK[u]), "lexicality carried into the weight coordinate")

def expected_resolve_w(c, o):  # independent reference for T11:
    cs, os_ = c[0], o[0]       # weighted resolution = unweighted resolution,
    if cs == 2 and os_ == 2: base = "CONFLICT"   # except the (1,1) tie
    elif cs == 2: base = "required"              # which weight alone may break
    elif os_ == 2: base = "forbidden"
    elif cs == 1 and os_ == 1: base = "neutral"
    elif cs == 1: base = "encouraged"
    elif os_ == 1: base = "discouraged"
    else: base = "neutral"
    if base == "neutral" and cs == 1 and os_ == 1:
        if c[1] > o[1]: return "encouraged"
        if o[1] > c[1]: return "discouraged"
        return "neutral_gated"
    return base

law("T11 resolve_w pinned over all states", all(
    resolve_w(c, o) == expected_resolve_w(c, o)
    for c in CLAIMS for o in CLAIMS),
    "all 81 (strength,weight)^2 states — including every strength-2 branch (audit F-1)")
law("T12 weight never breaks conflict", all(
    resolve_w((2, w1), (2, w2)) == "CONFLICT"
    for w1 in range(3) for w2 in range(3)),
    "(2,2) refuses for every weight pair; only the precedence ladder may resolve it")

if all(ok for _, ok in checks):
    print(f"\nRESULT: all {len(checks)} laws hold by total enumeration "
          f"({len(NORMS)} norms, {len(pairs_acts)} conflict triples, {len(CLAIMS)}^3 fold triples).")
    raise SystemExit(0)
print("\nRESULT: FAILURE — model refuted.")
raise SystemExit(1)
