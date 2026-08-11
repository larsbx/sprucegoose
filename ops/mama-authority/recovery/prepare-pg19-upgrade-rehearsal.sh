#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

root="$HOME/recovery-rehearsal/pg19-upgrade-check"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
pgdata_guard="$script_dir/assert-disposable-pgdata.sh"
old_data="$root/pg16-data"
new_data="$root/pg19-data"
socket_dir="$root/socket"
work_dir="$root/work"
log_dir="$root/logs"
live_env="$HOME/.config/sprucegoose/service.env"
old_root="$HOME/pglocal/usr/lib/postgresql/16"
new_root="$HOME/recovery-rehearsal/pgsql19"
old_port=55431
new_port=55432
run_id="${CORR7_REHEARSAL_RUN_ID:?CORR7_REHEARSAL_RUN_ID is required}"
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]]
script_sha="$(sha256sum "${BASH_SOURCE[0]}" | cut -d' ' -f1)"
started=0
probe_hold="${CORR7_REHEARSAL_HOLD_AFTER_CLONE_START_SECONDS:-0}"
[[ "$probe_hold" =~ ^[0-9]+$ && "$probe_hold" -le 120 ]]

hold_for_signal_probe() {
  local deadline=$((SECONDS + probe_hold))
  while (( SECONDS < deadline )); do
    sleep 0.2
  done
}

cleanup_process() {
  if [[ "$started" == 1 ]]; then
    LD_LIBRARY_PATH="$HOME/pglocal/usr/lib/x86_64-linux-gnu" \
      "$old_root/bin/pg_ctl" -D "$old_data" -m fast -w stop >/dev/null 2>&1 || true
  fi
}
trap cleanup_process EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "$(systemctl --user show sprucegoose-postgresql.service -p ActiveState --value)" == active ]]
[[ "$(systemctl --user show sprucegoose.service -p ActiveState --value)" == active ]]
live_postmaster_pid="$(systemctl --user show sprucegoose-postgresql.service -p MainPID --value)"
[[ "$live_postmaster_pid" =~ ^[1-9][0-9]*$ ]]
actual_live_pgdata="$(python3 - "$live_postmaster_pid" <<'PY'
import sys

args = open(f"/proc/{sys.argv[1]}/cmdline", "rb").read().split(b"\0")
for index, arg in enumerate(args[:-1]):
    if arg == b"-D" and index + 1 < len(args):
        print(args[index + 1].decode())
        break
else:
    raise SystemExit("running postmaster has no -D PGDATA argument")
PY
)"
"$pgdata_guard" "$root" "$HOME/pgdata" "$actual_live_pgdata" >/dev/null
[[ -f "$live_env" && ! -L "$live_env" ]]
[[ -x "$old_root/bin/pg_basebackup" ]]
[[ -x "$new_root/bin/pg_upgrade" ]]
[[ "$old_data" != "$HOME/pgdata" && "$new_data" != "$HOME/pgdata" ]]

set -a
# shellcheck disable=SC1090
. "$live_env"
set +a

mapfile -t db_parts < <(python3 - <<'PY'
import os
from urllib.parse import urlparse, unquote
u=urlparse(os.environ['DATABASE_URL'])
print(unquote(u.username or ''))
print(unquote(u.password or ''))
print(u.hostname or '/tmp')
print(u.port or 5432)
print((u.path or '/').lstrip('/'))
PY
)
DBUSER="${db_parts[0]}"
DBPASS="${db_parts[1]}"
DBHOST="${db_parts[2]}"
DBPORT="${db_parts[3]}"
LIVE_DB="${db_parts[4]}"
[[ "$DBUSER" == postgres ]]
[[ "$LIVE_DB" == spruce_goose_dev ]]

rm -rf -- "$root"
install -d -m 0700 "$root" "$socket_dir" "$work_dir" "$log_dir"
printf '%s\n' "$run_id" > "$root/run-id"
touch "$root/run-start"

export PGPASSWORD="$DBPASS"
export LD_LIBRARY_PATH="$HOME/pglocal/usr/lib/x86_64-linux-gnu"
"$old_root/bin/pg_basebackup" \
  --host="$DBHOST" --port="$DBPORT" --username="$DBUSER" \
  --pgdata="$old_data" --format=plain --wal-method=stream \
  --checkpoint=fast --no-password >"$log_dir/pg_basebackup.log" 2>&1
chmod 0700 "$old_data"

started=1
"$old_root/bin/pg_ctl" -D "$old_data" -l "$log_dir/pg16-clone.log" \
  -o "-p $old_port -k $socket_dir -c listen_addresses=" -w start >"$log_dir/pg16-start.log" 2>&1
hold_for_signal_probe
clone_version="$("$old_root/bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'show server_version' -h "$socket_dir" -p "$old_port" -U "$DBUSER" -d "$LIVE_DB")"
clone_migrations="$("$old_root/bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'select count(*) from schema_migrations' -h "$socket_dir" -p "$old_port" -U "$DBUSER" -d "$LIVE_DB")"
[[ "$clone_version" == 16.* ]]
[[ "$clone_migrations" == 24 ]]
"$old_root/bin/pg_ctl" -D "$old_data" -m fast -w stop >"$log_dir/pg16-stop.log" 2>&1
started=0

unset LD_LIBRARY_PATH
"$new_root/bin/initdb" --pgdata="$new_data" --encoding=UTF8 \
  --locale=en_US.UTF-8 --no-data-checksums --auth-local=trust --auth-host=reject \
  --username="$DBUSER" \
  >"$log_dir/pg19-initdb.log" 2>&1

cd "$work_dir"
export LD_LIBRARY_PATH="$new_root/lib:$HOME/pglocal/usr/lib/x86_64-linux-gnu"
"$new_root/bin/pg_upgrade" --check \
  --old-bindir="$old_root/bin" --new-bindir="$new_root/bin" \
  --old-datadir="$old_data" --new-datadir="$new_data" \
  --old-port="$old_port" --new-port="$new_port" --socketdir="$socket_dir" \
  --username="$DBUSER" \
  >"$log_dir/pg_upgrade-check.log" 2>&1

old_system_identifier="$("$old_root/bin/pg_controldata" "$old_data" | sed -n 's/^Database system identifier:[[:space:]]*//p')"
new_system_identifier="$(LD_LIBRARY_PATH="$new_root/lib:$HOME/pglocal/usr/lib/x86_64-linux-gnu" "$new_root/bin/pg_controldata" "$new_data" | sed -n 's/^Database system identifier:[[:space:]]*//p')"
[[ "$old_system_identifier" =~ ^[0-9]+$ && "$new_system_identifier" =~ ^[0-9]+$ ]]
{
  printf 'run_id=%s\n' "$run_id"
  printf 'prepared_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'old_system_identifier=%s\n' "$old_system_identifier"
  printf 'new_system_identifier=%s\n' "$new_system_identifier"
  printf 'prepare_script_sha256=%s\n' "$script_sha"
  printf 'pg_basebackup_log_sha256=%s\n' "$(sha256sum "$log_dir/pg_basebackup.log" | cut -d' ' -f1)"
  printf 'pg_upgrade_check_log_sha256=%s\n' "$(sha256sum "$log_dir/pg_upgrade-check.log" | cut -d' ' -f1)"
} > "$root/compatibility-manifest.txt"
chmod 0600 "$root/run-id" "$root/run-start" "$root/compatibility-manifest.txt"

unset PGPASSWORD DATABASE_URL TOKEN_SIGNING_SECRET DBPASS LD_LIBRARY_PATH
[[ "$(systemctl --user show sprucegoose-postgresql.service -p ActiveState --value)" == active ]]
[[ "$(systemctl --user show sprucegoose.service -p ActiveState --value)" == active ]]
printf 'physical_clone_version=%s\n' "$clone_version"
printf 'physical_clone_migrations=%s\n' "$clone_migrations"
printf 'pg_upgrade_check=PASS\n'
printf 'live_services=active\n'
