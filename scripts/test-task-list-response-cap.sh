#!/usr/bin/env bash
# Regression test for tsk-20260819T191826Z-f9be9cc9:
# unfiltered `sprucegoose task list` must succeed.
#
# Bug: the thin client (scripts/sprucegoose-client.py, deployed as ./sprucegoose)
# aborts with {"ok":false,"error":"response too large"} and exit 2 when the
# Unix-socket HTTP response exceeds its hard 1_048_576-byte recv cap. The
# unfiltered task list corpus exceeded that cap on 2026-08-19 (~1.14 MB
# per-state sum; completed tasks alone ~820 KB).
#
# This test asserts the DESIRED behavior. It FAILS while the bug is present
# and must PASS after remediation (pagination, streaming, summary default,
# raised cap, or equivalent) without weakening machine-readable output.
set -u
cd "$(dirname "$0")/.."

out=$(./sprucegoose task list 2>&1)
status=$?

if [ "$status" -ne 0 ]; then
  echo "FAIL: unfiltered 'task list' exited $status: $(printf '%s' "$out" | head -c 200)" >&2
  exit 1
fi

ok=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))' 2>/dev/null)
if [ "$ok" != "True" ]; then
  echo "FAIL: unfiltered 'task list' did not return ok:true JSON" >&2
  exit 1
fi

echo "PASS: unfiltered 'task list' succeeded ($(printf '%s' "$out" | wc -c) bytes)"
