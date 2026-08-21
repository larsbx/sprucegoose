#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

root="$HOME/recovery-rehearsal/pg19-upgrade-check"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
pgdata_guard="$script_dir/assert-disposable-pgdata.sh"
old_data="$root/pg16-data"
new_data="$root/pg19-data"
socket_dir="$root/socket"
work_dir="$root/upgrade-work"
evidence="$root/evidence"
log_dir="$root/logs"
live_env="$HOME/.config/sprucegoose/service.env"
old_root="$HOME/pglocal/usr/lib/postgresql/16"
new_root="$HOME/recovery-rehearsal/pgsql19"
old_lib="$HOME/pglocal/usr/lib/x86_64-linux-gnu"
old_port=55431
new_port=55432
run_id="${CORR7_REHEARSAL_RUN_ID:?CORR7_REHEARSAL_RUN_ID is required}"
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]]
script_sha="$(sha256sum "${BASH_SOURCE[0]}" | cut -d' ' -f1)"
DBUSER=postgres
LIVE_DB=spruce_goose_dev
running=""

stop_clone() {
  if [[ "$running" == old ]]; then
    LD_LIBRARY_PATH="$old_lib" "$old_root/bin/pg_ctl" -D "$old_data" -m fast -w stop >/dev/null 2>&1 || true
  elif [[ "$running" == new ]]; then
    LD_LIBRARY_PATH="$new_root/lib:$old_lib" "$new_root/bin/pg_ctl" -D "$new_data" -m fast -w stop >/dev/null 2>&1 || true
  fi
}

finalize_exit() {
  local exit_status=$? cleanup_failed=0
  trap - EXIT
  stop_clone
  if [[ -d "$old_data" ]] && LD_LIBRARY_PATH="$old_lib" "$old_root/bin/pg_ctl" -D "$old_data" status >/dev/null 2>&1; then
    cleanup_failed=1
  fi
  if [[ -d "$new_data" ]] && LD_LIBRARY_PATH="$new_root/lib:$old_lib" "$new_root/bin/pg_ctl" -D "$new_data" status >/dev/null 2>&1; then
    cleanup_failed=1
  fi
  [[ "$(systemctl --user show sprucegoose-postgresql.service -p ActiveState --value)" == active ]] || cleanup_failed=1
  [[ "$(systemctl --user show sprucegoose.service -p ActiveState --value)" == active ]] || cleanup_failed=1
  if [[ "$cleanup_failed" == 1 ]]; then
    printf 'rehearsal cleanup verification failed\n' >&2
    exit_status=1
  fi
  exit "$exit_status"
}
trap finalize_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

capture_inventory() {
  local psql=$1 port=$2 destination=$3 count table
  {
    "$psql" -X -v ON_ERROR_STOP=1 -At -h "$socket_dir" -p "$port" -U "$DBUSER" -d "$LIVE_DB" \
      -c "select 'migration' || E'\\t' || version::text from schema_migrations order by version"
    "$psql" -X -v ON_ERROR_STOP=1 -At -h "$socket_dir" -p "$port" -U "$DBUSER" -d "$LIVE_DB" \
      -c "select 'extension' || E'\\t' || extname || E'\\t' || extversion from pg_extension order by extname"
    "$psql" -X -v ON_ERROR_STOP=1 -At -h "$socket_dir" -p "$port" -U "$DBUSER" -d "$LIVE_DB" \
      -c "select 'role' || E'\\t' || rolname || E'\\t' || rolsuper || E'\\t' || rolinherit || E'\\t' || rolcreaterole || E'\\t' || rolcreatedb || E'\\t' || rolcanlogin || E'\\t' || rolreplication || E'\\t' || rolbypassrls || E'\\t' || rolconnlimit || E'\\t' || coalesce(rolvaliduntil::text, '') || E'\\t' || encode(sha256(convert_to(coalesce(rolpassword, ''), 'UTF8')), 'hex') from pg_authid where rolname !~ '^pg_' order by rolname"
    "$psql" -X -v ON_ERROR_STOP=1 -At -h "$socket_dir" -p "$port" -U "$DBUSER" -d "$LIVE_DB" \
      -c "select 'role_setting' || E'\\t' || coalesce(role.rolname, '*') || E'\\t' || coalesce(database.datname, '*') || E'\\t' || array_to_string(setting.setconfig, E'\\x1f') from pg_db_role_setting setting left join pg_roles role on role.oid=setting.setrole left join pg_database database on database.oid=setting.setdatabase where setting.setrole=0 or role.rolname !~ '^pg_' order by coalesce(role.rolname, '*'), database.datname nulls first"
    "$psql" -X -v ON_ERROR_STOP=1 -At -h "$socket_dir" -p "$port" -U "$DBUSER" -d "$LIVE_DB" \
      -c "select 'membership' || E'\\t' || role.rolname || E'\\t' || member.rolname || E'\\t' || grantor.rolname || E'\\t' || membership.admin_option || E'\\t' || membership.inherit_option || E'\\t' || membership.set_option from pg_auth_members membership join pg_roles role on role.oid=membership.roleid join pg_roles member on member.oid=membership.member join pg_roles grantor on grantor.oid=membership.grantor where role.rolname !~ '^pg_' or member.rolname !~ '^pg_' order by role.rolname, member.rolname, grantor.rolname"
    while IFS= read -r table; do
      count="$("$psql" -X -v ON_ERROR_STOP=1 -At -h "$socket_dir" -p "$port" -U "$DBUSER" -d "$LIVE_DB" -c "select count(*) from $table")"
      printf 'table\t%s\t%s\n' "$table" "$count"
    done < <("$psql" -X -v ON_ERROR_STOP=1 -At -h "$socket_dir" -p "$port" -U "$DBUSER" -d "$LIVE_DB" \
      -c "select format('%I.%I', n.nspname, c.relname) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p') order by 1")
  } > "$destination"
  chmod 0600 "$destination"
}

[[ "$(systemctl --user show sprucegoose-postgresql.service -p ActiveState --value)" == active ]]
[[ "$(systemctl --user show sprucegoose.service -p ActiveState --value)" == active ]]
[[ -f "$live_env" && ! -L "$live_env" ]]
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
"$pgdata_guard" "$old_data" "$HOME/pgdata" "$actual_live_pgdata" >/dev/null
"$pgdata_guard" "$new_data" "$HOME/pgdata" "$actual_live_pgdata" >/dev/null
[[ -x "$new_root/bin/pg_upgrade" ]]
[[ "$(<"$root/run-id")" == "$run_id" ]]
[[ "$log_dir/pg_upgrade-check.log" -nt "$root/run-start" ]]
grep -Fqx "run_id=$run_id" "$root/compatibility-manifest.txt"
old_system_identifier="$("$old_root/bin/pg_controldata" "$old_data" | sed -n 's/^Database system identifier:[[:space:]]*//p')"
new_system_identifier="$(LD_LIBRARY_PATH="$new_root/lib:$old_lib" "$new_root/bin/pg_controldata" "$new_data" | sed -n 's/^Database system identifier:[[:space:]]*//p')"
grep -Fqx "old_system_identifier=$old_system_identifier" "$root/compatibility-manifest.txt"
grep -Fqx "new_system_identifier=$new_system_identifier" "$root/compatibility-manifest.txt"
grep -Fq 'Clusters are compatible' "$log_dir/pg_upgrade-check.log"
"$pgdata_guard" "$evidence" "$HOME/pgdata" "$actual_live_pgdata" >/dev/null
rm -rf -- "$evidence"
install -d -m 0700 "$evidence"
"$pgdata_guard" "$work_dir" "$HOME/pgdata" "$actual_live_pgdata" >/dev/null
rm -rf -- "$work_dir"
install -d -m 0700 "$work_dir"

export LD_LIBRARY_PATH="$old_lib"
running=old
"$old_root/bin/pg_ctl" -D "$old_data" -l "$log_dir/pg16-inventory.log" \
  -o "-p $old_port -k $socket_dir -c listen_addresses=" -w start >/dev/null
"$old_root/bin/psql" -X -v ON_ERROR_STOP=1 -h "$socket_dir" -p "$old_port" -U "$DBUSER" \
  -d postgres -c "alter database $LIVE_DB set corr7.rehearsal_inventory_marker = 'preserved'" \
  >/dev/null
capture_inventory "$old_root/bin/psql" "$old_port" "$evidence/before.tsv"
"$old_root/bin/pg_ctl" -D "$old_data" -m fast -w stop >/dev/null
running=""

cd "$work_dir"
export LD_LIBRARY_PATH="$new_root/lib:$old_lib"
"$new_root/bin/pg_upgrade" \
  --old-bindir="$old_root/bin" --new-bindir="$new_root/bin" \
  --old-datadir="$old_data" --new-datadir="$new_data" \
  --old-port="$old_port" --new-port="$new_port" --socketdir="$socket_dir" \
  --username="$DBUSER" >"$log_dir/pg_upgrade.log" 2>&1

running=new
"$new_root/bin/pg_ctl" -D "$new_data" -l "$log_dir/pg19-upgraded.log" \
  -o "-p $new_port -k $socket_dir -c listen_addresses=" -w start >/dev/null
new_version="$("$new_root/bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'show server_version' -h "$socket_dir" -p "$new_port" -U "$DBUSER" -d "$LIVE_DB")"
[[ "$new_version" == 19beta2* ]]
capture_inventory "$new_root/bin/psql" "$new_port" "$evidence/after.tsv"
diff -u "$evidence/before.tsv" "$evidence/after.tsv" > "$evidence/inventory.diff"
[[ ! -s "$evidence/inventory.diff" ]]
"$new_root/bin/vacuumdb" --all --analyze-in-stages -h "$socket_dir" -p "$new_port" -U "$DBUSER" >"$log_dir/vacuumdb.log" 2>&1
"$new_root/bin/pg_ctl" -D "$new_data" -m fast -w stop >/dev/null
running=""

upgraded_system_identifier="$(LD_LIBRARY_PATH="$new_root/lib:$old_lib" "$new_root/bin/pg_controldata" "$new_data" | sed -n 's/^Database system identifier:[[:space:]]*//p')"
{
  printf 'run_id=%s\n' "$run_id"
  printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'upgrade_script_sha256=%s\n' "$script_sha"
  printf 'compatibility_manifest_sha256=%s\n' "$(sha256sum "$root/compatibility-manifest.txt" | cut -d' ' -f1)"
  printf 'old_system_identifier=%s\n' "$old_system_identifier"
  printf 'upgraded_system_identifier=%s\n' "$upgraded_system_identifier"
} > "$evidence/upgrade-manifest.txt"
(
  cd "$evidence"
  sha256sum before.tsv after.tsv inventory.diff upgrade-manifest.txt > SHA256SUMS
)
chmod 0600 "$evidence"/*

[[ "$(systemctl --user show sprucegoose-postgresql.service -p ActiveState --value)" == active ]]
[[ "$(systemctl --user show sprucegoose.service -p ActiveState --value)" == active ]]
printf 'upgraded_clone_version=%s\n' "$new_version"
printf 'inventory_match=PASS\n'
printf 'analyze_in_stages=PASS\n'
printf 'live_services=active\n'
