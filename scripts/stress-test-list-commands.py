#!/usr/bin/env python3
"""Adversarial probe for `sprucegoose task list` / `workflow list`.

Contract this harness assumes (verified against the live CLI):
  - Success: JSON envelope on STDOUT, exit code 0.
  - Failure: JSON envelope on STDERR, exit code 2.

An earlier version of this harness parsed only stdout. Error envelopes go to
stderr, so `doc` was None on every negative case and `doc.get("ok") is False`
was never true -- 13 cases reported FAIL against a CLI that was behaving
correctly. Parse both streams, and assert the exit code as part of the
contract rather than ignoring it.
"""

import json
import subprocess
import sys

CLI = "/home/admin-papa/sprucegoose/sprucegoose"
results = []


def run(*args):
    p = subprocess.run([CLI] + list(args), capture_output=True, text=True, timeout=120)
    return p.returncode, p.stdout.strip(), p.stderr.strip()


def parse(stream):
    if not stream:
        return None
    try:
        return json.loads(stream)
    except Exception:
        return None


def case(name, args, check):
    """Run a case. `check` receives (rc, doc, out_doc, err_doc).

    `doc` is the envelope from whichever stream carried it (stdout preferred),
    so success and failure cases can be checked uniformly.
    """
    rc, out, err = run(*args)
    out_doc, err_doc = parse(out), parse(err)
    doc = out_doc if out_doc is not None else err_doc
    verdict, note = check(rc, doc, out_doc, err_doc)
    results.append((verdict, name, " ".join(args), note))
    return doc


def record(cond, name, cmd, note):
    results.append(("PASS" if cond else "FAIL", name, cmd, note))


def ok_case(name, args, check):
    """Assert a success contract: rc==0, envelope on stdout, ok==true."""

    def wrapped(rc, doc, out_doc, err_doc):
        if rc != 0:
            return "FAIL", f"expected rc=0, got rc={rc}; err={(err_doc or {}).get('error')}"
        if out_doc is None:
            return "FAIL", "success envelope not on stdout"
        if not out_doc.get("ok"):
            return "FAIL", f"ok={out_doc.get('ok')}"
        return check(out_doc)

    return case(name, args, wrapped)


def reject_case(name, args, note):
    """Assert a rejection contract: rc==2, envelope on stderr, ok==false."""

    def wrapped(rc, doc, out_doc, err_doc):
        if err_doc is None:
            return "FAIL", f"no JSON error envelope on stderr (rc={rc})"
        if err_doc.get("ok") is not False:
            return "FAIL", f"expected ok=false, got ok={err_doc.get('ok')}"
        if rc != 2:
            return "FAIL", f"expected rc=2, got rc={rc}"
        return "PASS", f'{note}; rejected with "{err_doc.get("error")}"'

    return case(name, args, wrapped)


# ---------------------------------------------------------------- baselines
allt = ok_case(
    "task list (no filter)",
    ["task", "list"],
    lambda d: ("PASS", f"n={len(d['tasks'])} total={d.get('total')}")
    if isinstance(d.get("tasks"), list)
    else ("FAIL", "tasks not a list"),
)
N = len(allt["tasks"]) if allt and allt.get("tasks") is not None else 0

allw = ok_case(
    "workflow list (no filter)",
    ["workflow", "list"],
    lambda d: ("PASS", f"n={len(d.get('workflows', []))}"),
)
W = len(allw["workflows"]) if allw and allw.get("workflows") is not None else 0

# membership names exposed on task rows
t0 = allt["tasks"][0] if N else {}
keys = set(t0.keys())
record(
    {"project", "roadmap", "workflow"} <= keys,
    "task list exposes project/roadmap/workflow names",
    "task list",
    f"membership keys present={sorted({'project', 'roadmap', 'workflow'} & keys)}",
)

# ------------------------------------------------------- state partitioning
states = [
    "inbox", "proposed", "queued", "ready", "in_progress",
    "waiting", "blocked", "completed", "cancelled",
]
tot = 0
for s in states:
    d = ok_case(
        f"task list --state {s}",
        ["task", "list", "--state", s],
        lambda d: ("PASS", f"n={len(d['tasks'])}"),
    )
    if d and d.get("ok"):
        tot += len(d["tasks"])
record(tot == N, "state filters partition full set", "sum(states) vs all", f"sum={tot} all={N}")

# multi-state selection
ok_case(
    "task list --state in_progress,waiting",
    ["task", "list", "--state", "in_progress,waiting"],
    lambda d: ("PASS", f"n={len(d['tasks'])}"),
)

# ----------------------------------------------------------- invalid inputs
reject_case("task list --state bogus", ["task", "list", "--state", "bogus"], "unknown state")
reject_case("task list --priority 99", ["task", "list", "--priority", "99"], "out-of-range priority")
reject_case("task list --priority abc", ["task", "list", "--priority", "abc"], "non-int priority")
reject_case("task list --project nope", ["task", "list", "--project", "nope"], "unknown project")
reject_case("task list --workflow nope", ["task", "list", "--workflow", "nope"], "unknown workflow")
reject_case("task list --unknownflag x", ["task", "list", "--unknownflag", "x"], "unknown flag")
reject_case("task list stray positional", ["task", "list", "garbage"], "positional arg")
reject_case("task list --format table", ["task", "list", "--format", "table"], "unsupported --format")

# ------------------------------------------------------ pagination / sorting
ok_case(
    "task list --limit 5",
    ["task", "list", "--limit", "5"],
    lambda d: ("PASS", f"n={len(d['tasks'])} total={d.get('total')}")
    if len(d.get("tasks", [])) == 5
    else ("FAIL", f"expected 5 rows, got {len(d.get('tasks', []))}"),
)
ok_case(
    "task list --offset 5",
    ["task", "list", "--offset", "5"],
    lambda d: ("PASS", f"n={len(d['tasks'])} offset={d.get('offset')}"),
)

# offset must actually shift the window, not just be accepted
page1 = run("task", "list", "--limit", "3", "--sort", "id")
page2 = run("task", "list", "--limit", "3", "--offset", "3", "--sort", "id")
d1, d2 = parse(page1[1]), parse(page2[1])
if d1 and d2 and d1.get("ok") and d2.get("ok"):
    ids1 = [t["id"] for t in d1["tasks"]]
    ids2 = [t["id"] for t in d2["tasks"]]
    record(
        not (set(ids1) & set(ids2)) and len(ids1) == 3 and len(ids2) == 3,
        "offset yields a disjoint page",
        "--limit 3 --offset 3",
        f"overlap={sorted(set(ids1) & set(ids2))}",
    )
else:
    record(False, "offset yields a disjoint page", "--limit 3 --offset 3", "pagination query failed")

for key in ["id", "recent", "priority", "state", "title", "created"]:
    ok_case(
        f"task list --sort {key}",
        ["task", "list", "--sort", key],
        lambda d: ("PASS", f"n={len(d['tasks'])}"),
    )

# Sorting must actually order rows, asserted as a property rather than a
# specific winner: task IDs carry only second granularity and tiebreak on
# random hex, so which of two same-second tasks wins is undefined.
# `--sort id` is ascending by design; `--sort recent` is the descending variant.
d = parse(run("task", "list", "--sort", "id", "--limit", "50")[1])
if d and d.get("ok"):
    ids = [t["id"] for t in d["tasks"]]
    record(ids == sorted(ids), "--sort id is genuinely ordered", "--sort id", "ascending")
else:
    record(False, "--sort id is genuinely ordered", "--sort id", "query failed")

d = parse(run("task", "list", "--sort", "recent", "--limit", "50")[1])
if d and d.get("ok"):
    ids = [t["id"] for t in d["tasks"]]
    record(
        ids == sorted(ids, reverse=True),
        "--sort recent is genuinely ordered",
        "--sort recent",
        "descending (most recent first)",
    )
else:
    record(False, "--sort recent is genuinely ordered", "--sort recent", "query failed")

reject_case("task list --sort bogus", ["task", "list", "--sort", "bogus"], "unknown sort key")

# ------------------------------------------------------- priority semantics
ok_case(
    "task list --priority 2",
    ["task", "list", "--priority", "2"],
    lambda d: ("PASS", f"n={len(d['tasks'])}"),
)

# legacy null-priority rows must be reachable via --priority none
nullp = [t for t in (allt or {"tasks": []})["tasks"] if t.get("priority") is None]
d = ok_case(
    "task list --priority none",
    ["task", "list", "--priority", "none"],
    lambda d: ("PASS", f"n={len(d['tasks'])}"),
)
reachable = len(d["tasks"]) if d and d.get("ok") else -1
record(
    reachable == len(nullp),
    "legacy null-priority tasks filterable",
    "--priority none",
    f"{len(nullp)} null-priority rows in full set, {reachable} reachable via --priority none",
)

# ------------------------------------------------------------- text search
ok_case(
    "task list --text stress",
    ["task", "list", "--text", "stress"],
    lambda d: ("PASS", f"n={len(d['tasks'])}")
    if any("stress" in t.get("title", "").lower() for t in d.get("tasks", []))
    else ("FAIL", "no title matched 'stress'"),
)
lower = parse(run("task", "list", "--text", "stress")[1])
upper = parse(run("task", "list", "--text", "STRESS")[1])
if lower and upper and lower.get("ok") and upper.get("ok"):
    record(
        len(lower["tasks"]) == len(upper["tasks"]),
        "text search is case-insensitive",
        "--text stress vs STRESS",
        f"lower={len(lower['tasks'])} upper={len(upper['tasks'])}",
    )
else:
    record(False, "text search is case-insensitive", "--text", "query failed")

# ------------------------------------------------------- workflow list
ok_case(
    "workflow list --project openclaw-system",
    ["workflow", "list", "--project", "openclaw-system"],
    lambda d: ("PASS", f"n={len(d.get('workflows', []))}"),
)
ok_case(
    "workflow list --roadmap driftless-ops",
    ["workflow", "list", "--roadmap", "driftless-ops"],
    lambda d: ("PASS", f"n={len(d.get('workflows', []))}"),
)
reject_case("workflow list --project nope", ["workflow", "list", "--project", "nope"], "unknown project")
reject_case("workflow list --workflow x", ["workflow", "list", "--workflow", "x"], "unsupported flag")
reject_case("workflow list --state active", ["workflow", "list", "--state", "active"], "unsupported flag")

# workflow rows carry task counts
w0 = (allw or {"workflows": []})["workflows"][0] if W else {}
record(
    "task_count" in w0 or "definition" in w0,
    "workflow list exposes definition or task counts",
    "workflow list",
    f"keys={sorted(w0.keys())}",
)

# ------------------------------------------- known defect: workflow_id ambiguity
seen = {}
for w in (allw or {"workflows": []})["workflows"]:
    seen.setdefault(w["workflow_id"], []).append(w["roadmap"])
dups = [(k, v) for k, v in seen.items() if len(v) > 1]
record(
    not dups,
    "workflow_id ambiguity across roadmaps",
    "--workflow ID",
    f"{len(dups)} duplicated ids e.g. {dups[:2]}"
    if dups
    else "no duplicate workflow_id across roadmaps",
)

# ----------------------------------------------------------------- report
print(json.dumps(
    [{"verdict": v, "case": n, "cmd": c, "note": x} for v, n, c, x in results], indent=1
))
f = sum(1 for v, _, _, _ in results if v == "FAIL")
print(f"\nTOTAL={len(results)} FAIL={f} PASS={len(results) - f}", file=sys.stderr)
sys.exit(1 if f else 0)
