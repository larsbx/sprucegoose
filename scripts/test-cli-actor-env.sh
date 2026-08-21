#!/usr/bin/env bash
# Regression test for tsk-20260820T205507Z-02e575eb:
# the thin socket client must honor a caller-side SPRUCE_GOOSE_ACTOR.
#
# Background: the service resolves the actor from `--as`, then from
# SPRUCE_GOOSE_ACTOR in ITS OWN environment. Through the socket client the
# service's environment is the daemon's, never the caller's shell, so the
# caller's variable silently vanished even though the refusal message tells
# the caller to set it. The client now translates the caller's environment
# into an explicit `--as ACTOR` when no flag was passed.
#
# Contract asserted here (all cases are read-only requests):
#   1. env-only, unknown actor  -> service refusal NAMES the env value,
#      proving the caller's variable reached the service.
#   2. flag-only, unknown actor -> refusal names the flag value (unchanged).
#   3. flag beats env           -> refusal names the flag value, not the env.
#   4. neither                  -> the original "no actor" refusal, unchanged.
#   5. env-only, registered actor -> request succeeds end to end.
set -u
cd "$(dirname "$0")/.."

CLI=./sprucegoose
ENV_ACTOR="regression-env-actor-does-not-exist"
FLAG_ACTOR="regression-flag-actor-does-not-exist"
REAL_ACTOR="${SPRUCE_GOOSE_TEST_ACTOR:-admin-papa}"
fails=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

# The service replies JSON, so quotes around the actor name arrive escaped
# (`unknown actor \"NAME\"`). Assert on the refusal kind and the exact name
# separately rather than reproducing the escaping in one brittle pattern.
names_unknown_actor() { # $1=output $2=expected-name
  printf '%s' "$1" | grep -q "unknown actor" &&
    printf '%s' "$1" | grep -q "$2"
}

# ------------------------------------------------ 1. env-only reaches service
out=$(env SPRUCE_GOOSE_ACTOR="$ENV_ACTOR" $CLI task list --limit 1 2>&1)
if names_unknown_actor "$out" "$ENV_ACTOR"; then
  pass "env-only SPRUCE_GOOSE_ACTOR reaches the service as --as"
else
  fail "env-only actor did not reach the service; got: $out"
fi

# ------------------------------------------------ 2. flag-only unchanged
out=$(env -u SPRUCE_GOOSE_ACTOR $CLI task list --limit 1 --as "$FLAG_ACTOR" 2>&1)
if names_unknown_actor "$out" "$FLAG_ACTOR"; then
  pass "explicit --as still reaches the service"
else
  fail "explicit --as behavior changed; got: $out"
fi

# ------------------------------------------------ 3. flag beats env
out=$(env SPRUCE_GOOSE_ACTOR="$ENV_ACTOR" $CLI task list --limit 1 --as "$FLAG_ACTOR" 2>&1)
if names_unknown_actor "$out" "$FLAG_ACTOR" &&
  ! printf '%s' "$out" | grep -q "$ENV_ACTOR"; then
  pass "explicit --as wins over SPRUCE_GOOSE_ACTOR"
else
  fail "explicit --as did not win over env; got: $out"
fi

# --as=NAME form must also win.
out=$(env SPRUCE_GOOSE_ACTOR="$ENV_ACTOR" $CLI task list --limit 1 --as="$FLAG_ACTOR" 2>&1)
if names_unknown_actor "$out" "$FLAG_ACTOR" &&
  ! printf '%s' "$out" | grep -q "$ENV_ACTOR"; then
  pass "explicit --as=NAME wins over SPRUCE_GOOSE_ACTOR"
else
  fail "--as=NAME did not win over env; got: $out"
fi

# ------------------------------------------------ 4. neither: refusal intact
out=$(env -u SPRUCE_GOOSE_ACTOR $CLI task list --limit 1 2>&1)
if printf '%s' "$out" | grep -q "no actor: pass --as NAME or set SPRUCE_GOOSE_ACTOR"; then
  pass "with neither set the fail-closed refusal is unchanged"
else
  fail "no-actor refusal changed; got: $out"
fi

# ------------------------------------------------ 5. env-only positive path
out=$(env SPRUCE_GOOSE_ACTOR="$REAL_ACTOR" $CLI task list --limit 1 2>/dev/null)
if printf '%s' "$out" |
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("ok") is True else 1)'; then
  pass "env-only request succeeds for registered actor $REAL_ACTOR"
else
  fail "env-only request failed for registered actor $REAL_ACTOR"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
fi
echo "$fails FAILURE(S)" >&2
exit 1
