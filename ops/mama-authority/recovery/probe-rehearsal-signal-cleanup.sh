#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

mode="${1:-}"
signal="${2:-TERM}"
run_id="${CORR7_REHEARSAL_RUN_ID:?CORR7_REHEARSAL_RUN_ID is required}"
expected_tree="${CORR7_EXPECTED_TREE:-not-applicable}"
expected_archive="${CORR7_EXPECTED_ARCHIVE_SHA256:-not-applicable}"
root="$HOME/recovery-rehearsal"
prepare="$root/prepare-pg19-upgrade-rehearsal.sh"
actor="$root/run-actor-migration-on-pg19-rehearsal.sh"
signal_evidence="$root/corr7-signal-evidence"
old_root="$HOME/pglocal/usr/lib/postgresql/16"
old_lib="$HOME/pglocal/usr/lib/x86_64-linux-gnu"
old_data="$root/pg19-upgrade-check/pg16-data"
new_root="$root/pgsql19"
new_data="$root/pg19-upgrade-check/pg19-data"
unit="sprucegoose-corr7-pg19.service"
pid=""

[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]]
case "$signal" in
  HUP) expected_status=129 ;;
  INT) expected_status=130 ;;
  TERM) expected_status=143 ;;
  *)
    printf 'usage: %s clone|app [HUP|INT|TERM]\n' "$0" >&2
    exit 64
    ;;
esac

cleanup_probe() {
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}
trap cleanup_probe EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

wait_until() {
  local attempt
  for ((attempt = 0; attempt < 300; attempt++)); do
    if "$@"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

old_clone_active() {
  LD_LIBRARY_PATH="$old_lib" "$old_root/bin/pg_ctl" -D "$old_data" status >/dev/null 2>&1
}

transient_app_active() {
  [[ "$(systemctl --user show "$unit" -p ActiveState --value 2>/dev/null)" == active ]]
}

assert_live_services() {
  [[ "$(systemctl --user show sprucegoose-postgresql.service -p ActiveState --value)" == active ]]
  [[ "$(systemctl --user show sprucegoose.service -p ActiveState --value)" == active ]]
}

start_target() {
  local target="$1"
  local hold_variable="$2"
  python3 - "$target" "$hold_variable" <<'PY' &
import os
import signal
import sys

signal.signal(signal.SIGHUP, signal.SIG_DFL)
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGTERM, signal.SIG_DFL)
environment = os.environ.copy()
environment[sys.argv[2]] = "120"
os.execve(sys.argv[1], [sys.argv[1]], environment)
PY
  pid=$!
}

interrupt_and_require_cleanup() {
  kill -s "$signal" "$pid"
  set +e
  wait "$pid"
  status=$?
  set -e
  pid=""
  [[ "$status" == "$expected_status" ]]
}

write_receipt() {
  local target_script="$1"
  local status="$2"
  local receipt tmp
  install -d -m 0700 "$signal_evidence"
  receipt="$signal_evidence/${run_id}-${mode}-${signal}.txt"
  [[ ! -e "$receipt" ]]
  tmp="$(mktemp "$signal_evidence/.receipt.XXXXXX")"
  {
    printf 'run_id=%s\n' "$run_id"
    printf 'mode=%s\n' "$mode"
    printf 'signal=%s\n' "$signal"
    printf 'expected_status=%s\n' "$expected_status"
    printf 'actual_status=%s\n' "$status"
    printf 'cleanup=PASS\n'
    printf 'live_postgresql=active\n'
    printf 'live_application=active\n'
    printf 'expected_tree=%s\n' "$expected_tree"
    printf 'expected_archive_sha256=%s\n' "$expected_archive"
    printf 'probe_script_sha256=%s\n' "$(sha256sum "${BASH_SOURCE[0]}" | cut -d' ' -f1)"
    printf 'target_script_sha256=%s\n' "$(sha256sum "$target_script" | cut -d' ' -f1)"
    printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$tmp"
  chmod 0400 "$tmp"
  mv -n -- "$tmp" "$receipt"
  [[ -f "$receipt" && ! -e "$tmp" ]]
  (
    cd -- "$(dirname -- "$receipt")"
    sha256sum -- "$(basename -- "$receipt")" > "$(basename -- "$receipt").sha256"
  )
  chmod 0400 "$receipt.sha256"
}

case "$mode" in
  clone)
    start_target "$prepare" CORR7_REHEARSAL_HOLD_AFTER_CLONE_START_SECONDS
    wait_until old_clone_active
    interrupt_and_require_cleanup
    actual_status="$expected_status"
    ! old_clone_active
    assert_live_services
    write_receipt "$prepare" "$actual_status"
    printf 'clone_signal=%s\nclone_signal_exit=%s\nclone_cleanup=PASS\nlive_services=active\n' "$signal" "$actual_status"
    ;;
  app)
    [[ "$expected_tree" =~ ^[0-9a-f]{40}$ ]]
    [[ "$expected_archive" =~ ^[0-9a-f]{64}$ ]]
    start_target "$actor" CORR7_REHEARSAL_HOLD_AFTER_APP_START_SECONDS
    wait_until transient_app_active
    interrupt_and_require_cleanup
    actual_status="$expected_status"
    [[ "$(systemctl --user show "$unit" -p ActiveState --value 2>/dev/null)" != active ]]
    ! LD_LIBRARY_PATH="$new_root/lib:$old_lib" "$new_root/bin/pg_ctl" -D "$new_data" status >/dev/null 2>&1
    assert_live_services
    write_receipt "$actor" "$actual_status"
    printf 'app_signal=%s\napp_signal_exit=%s\napp_cleanup=PASS\nlive_services=active\n' "$signal" "$actual_status"
    ;;
  *)
    printf 'usage: %s clone|app [HUP|INT|TERM]\n' "$0" >&2
    exit 64
    ;;
esac
