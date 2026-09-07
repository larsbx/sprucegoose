#!/usr/bin/env bash
# Shared doc-request helpers.
#
# The post-commit hook WRITES requests. The merge-time consumer READS them and
# hands each prompt to the SpruceGoose agent. Both sides share this file so the
# on-disk shape has exactly one definition.
#
# A request is an artifact, not an authorization. It records what changed and
# carries a prompt built from those facts. It confers no task, effect, or
# publication authority, and its own summary is never evidence of current
# state -- the consumer re-reads the repository at the recorded commit.
#
# Schema: sprucegoose.doc_request.v1
#   repository     slug, label only
#   commit, tree   the exact content the consumer must read
#   branch         branch at commit time
#   subject/author/committed_at
#   runtime_files  files that define how something runs
#   changed_files  everything in the commit
#   docs_changed   documentation touched in the same commit
#   state          pending | claimed | done | failed
#   prompt         the text handed to the agent
#
# Requests live in $GIT_DIR/doc-requests/<commit>.json, mode 0600. They are
# deliberately NOT tracked: generated request state does not belong in the
# history it describes.

DOC_REQUEST_SCHEMA='sprucegoose.doc_request.v1'

# doc_request_dir <repo-dir> -> prints the request directory
doc_request_dir() {
  local repo="${1:-.}" gitdir
  gitdir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  printf '%s/doc-requests' "$gitdir"
}

# doc_request_list <repo-dir> [state] -> prints matching request paths
doc_request_list() {
  local repo="${1:-.}" want="${2:-pending}" dir f st
  dir=$(doc_request_dir "$repo") || return 0
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    if [ "$want" = "all" ]; then
      printf '%s\n' "$f"
      continue
    fi
    st=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("state",""))' "$f" 2>/dev/null) || continue
    [ "$st" = "$want" ] && printf '%s\n' "$f"
  done
}

# doc_request_field <file> <field> -> prints one field
doc_request_field() {
  python3 -c '
import json,sys
v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
print("\n".join(v) if isinstance(v, list) else (v if v is not None else ""))
' "$1" "$2" 2>/dev/null
}

# doc_request_set_state <file> <state> [note]
# Atomic. Refuses an unknown state rather than writing a typo into the record.
doc_request_set_state() {
  python3 - "$1" "$2" "${3:-}" <<'PY' 2>/dev/null
import json, os, sys, tempfile, datetime

path, state, note = sys.argv[1], sys.argv[2], sys.argv[3]
if state not in ("pending", "claimed", "done", "failed"):
    sys.exit(2)

with open(path) as f:
    d = json.load(f)

d["state"] = state
d["state_changed_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
if note:
    d.setdefault("history", []).append({"state": state, "note": note,
                                        "at": d["state_changed_at"]})

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w") as f:
        json.dump(d, f, indent=2, sort_keys=True)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except Exception:
    try: os.unlink(tmp)
    except Exception: pass
    raise
PY
}
