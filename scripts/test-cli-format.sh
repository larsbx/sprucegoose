#!/usr/bin/env bash
# Regression test for tsk-20260819T192025Z-90abd50d:
# the SpruceGoose CLI must accept --format json|table|plain, defaulting to json.
#
# Contract asserted here:
#   1. Omitting --format produces byte-identical output to --format json,
#      so every existing JSON consumer is unaffected.
#   2. --format is a CLIENT-SIDE display transform. The service never sees it,
#      and the JSON contract stays canonical.
#   3. table/plain render aligned, column-headed output for list-shaped
#      commands and NEVER filter, reorder, truncate, or invent rows:
#        plain -> 1 header line + exactly N row lines
#        table -> 1 header line + 1 rule line + exactly N row lines
#      where N is the row count reported by the canonical JSON.
#   4. Row order matches JSON order, compared column-precisely (identifier
#      values are not unique across rows and may be substrings of one another,
#      so a whole-line substring search is not a valid instrument here).
#   5. An invalid --format value fails closed with JSON on stderr, exit 2.
#   6. Error responses stay machine-readable JSON regardless of --format.
#
# This test asserts the DESIRED behavior. It FAILS before implementation.
set -u
cd "$(dirname "$0")/.."

CLI=./sprucegoose
fails=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# ---------------------------------------------------------------- 1. default == json
default_out=$($CLI task list --state in_progress 2>/dev/null)
default_status=$?
json_out=$($CLI task list --state in_progress --format json 2>/dev/null)
json_status=$?

if [ "$default_status" -ne 0 ]; then
  fail "default 'task list --state in_progress' exited $default_status"
elif [ "$json_status" -ne 0 ]; then
  fail "'--format json' exited $json_status"
elif [ "$default_out" != "$json_out" ]; then
  fail "default output is not byte-identical to --format json"
else
  pass "default output is byte-identical to --format json"
fi

# Default output must still be the canonical JSON envelope.
if printf '%s' "$default_out" |
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("ok") is True and isinstance(d.get("tasks"),list) else 1)'; then
  pass "default output remains canonical ok:true JSON with tasks[]"
else
  fail "default output is no longer canonical JSON"
fi

# ---------------------------------------------------------------- 2. server never sees --format
# The service rejects unknown task-list flags. If --format leaked through to the
# service, this command would fail with "invalid task list arguments".
if $CLI task list --state in_progress --format table >/dev/null 2>&1; then
  pass "--format is stripped client-side (service did not reject it)"
else
  fail "--format leaked to the service or rendering failed"
fi

# ---------------------------------------------------------------- 3/4. row fidelity
# Checks a list command in both table and plain: no rows added, dropped,
# reordered, or truncated relative to the canonical JSON.
check_rows() {
  local label="$1" key="$2" idfield="$3"
  shift 3
  local -a cmd=("$@")

  local canonical count
  canonical=$("$CLI" "${cmd[@]}" --format json 2>/dev/null) || {
    fail "$label: --format json failed"
    return
  }
  count=$(printf '%s' "$canonical" |
    python3 -c "import json,sys; print(len(json.load(sys.stdin)['$key']))" 2>/dev/null)
  if [ -z "$count" ]; then
    fail "$label: could not read '$key' from canonical JSON"
    return
  fi
  if [ "$count" -eq 0 ]; then
    echo "SKIP: $label has 0 rows; nothing to render"
    return
  fi

  local plain_out table_out plain_lines table_lines
  plain_out=$("$CLI" "${cmd[@]}" --format plain 2>/dev/null) || {
    fail "$label: --format plain failed"
    return
  }
  table_out=$("$CLI" "${cmd[@]}" --format table 2>/dev/null) || {
    fail "$label: --format table failed"
    return
  }
  plain_lines=$(printf '%s\n' "$plain_out" | wc -l)
  table_lines=$(printf '%s\n' "$table_out" | wc -l)

  # plain: header + N rows. table: header + rule + N rows.
  if [ "$plain_lines" -ne "$((count + 1))" ]; then
    fail "$label: plain emitted $plain_lines lines, expected $((count + 1)) (header + $count rows)"
  else
    pass "$label: plain emitted header + exactly $count rows"
  fi
  if [ "$table_lines" -ne "$((count + 2))" ]; then
    fail "$label: table emitted $table_lines lines, expected $((count + 2)) (header + rule + $count rows)"
  else
    pass "$label: table emitted header + rule + exactly $count rows"
  fi

  # Compare the rendered identifier COLUMN, in order, against the JSON order.
  # Identifier values repeat across rows and embed in one another, so this
  # extracts the exact tab-delimited column rather than searching whole lines.
  local expected actual
  expected=$(printf '%s' "$canonical" |
    python3 -c "import json,sys; [print(r.get('$idfield','')) for r in json.load(sys.stdin)['$key']]")
  actual=$(printf '%s\n' "$plain_out" |
    python3 -c "
import sys
lines = sys.stdin.read().split('\n')
header = lines[0].split('\t')
col = header.index('$idfield')
for line in lines[1:]:
    if line:
        print(line.split('\t')[col])
")
  if [ "$expected" = "$actual" ]; then
    pass "$label: $idfield column matches JSON order exactly ($count rows)"
  else
    fail "$label: $idfield column diverges from JSON order/content"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | head -6 >&2
  fi
}

check_rows "task list --state in_progress" tasks id task list --state in_progress
check_rows "task list --limit 5" tasks id task list --limit 5
check_rows "project list" projects key project list
check_rows "roadmap list" roadmaps key roadmap list
check_rows "workflow list" workflows workflow_id workflow list
check_rows "inbox list" items id inbox list

# `todo list` is list-shaped but requires a task id. Discover a task that
# actually has todos rather than hard-coding one, so this stays meaningful as
# the corpus changes.
todo_task=$(
  $CLI task list --state in_progress --format json 2>/dev/null |
    python3 -c 'import json,sys; [print(t["id"]) for t in json.load(sys.stdin)["tasks"]]' 2>/dev/null |
    while IFS= read -r tid; do
      n=$($CLI todo list "$tid" --format json 2>/dev/null |
        python3 -c 'import json,sys; print(len(json.load(sys.stdin)["todos"]))' 2>/dev/null)
      if [ -n "$n" ] && [ "$n" -gt 0 ]; then
        echo "$tid"
        break
      fi
    done
)
if [ -n "$todo_task" ]; then
  check_rows "todo list $todo_task" todos id todo list "$todo_task"
else
  echo "SKIP: no in_progress task currently has todos"
fi

# ---------------------------------------------------------------- 5. invalid value fails closed
bad_err=$($CLI task list --state in_progress --format yaml 2>&1 >/dev/null)
bad_status=$?
if [ "$bad_status" -eq 0 ]; then
  fail "--format yaml was accepted; must fail closed"
elif printf '%s' "$bad_err" |
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("ok") is False and d.get("error") else 1)' 2>/dev/null; then
  pass "invalid --format value fails closed with JSON error on stderr"
else
  fail "invalid --format value did not emit a JSON error object: $(printf '%s' "$bad_err" | head -c 120)"
fi

# Missing value must also fail closed rather than swallowing the next argument.
if $CLI task list --format >/dev/null 2>&1; then
  fail "'--format' with no value was accepted"
else
  pass "'--format' with no value fails closed"
fi

# ---------------------------------------------------------------- 6. errors stay JSON
err_out=$($CLI task show tsk-does-not-exist-00000000 --format table 2>&1 >/dev/null)
if printf '%s' "$err_out" |
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("ok") is False else 1)' 2>/dev/null; then
  pass "service errors stay machine-readable JSON under --format table"
else
  fail "service error was not JSON under --format table: $(printf '%s' "$err_out" | head -c 120)"
fi

# ---------------------------------------------------------------- 7. non-list commands
# A non-list command has no rows to align; it must still succeed and stay JSON.
# Uses `version` (not `meta version`): the deployed authority server predates
# the `meta` noun, so `meta version` is unsupported there.
if $CLI version --format table 2>/dev/null |
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("ok") is True else 1)' 2>/dev/null; then
  pass "non-list command under --format table falls back to JSON"
else
  fail "non-list command under --format table did not return ok JSON"
fi

echo
if [ "$fails" -ne 0 ]; then
  echo "FAILED: $fails assertion(s)" >&2
  exit 1
fi
echo "OK: --format contract satisfied"
