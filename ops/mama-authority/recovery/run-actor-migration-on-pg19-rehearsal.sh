#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

root="$HOME/recovery-rehearsal"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
pgdata_guard="$script_dir/assert-disposable-pgdata.sh"
pg_root="$root/pg19-upgrade-check"
pg_data="$pg_root/pg19-data"
pg_socket="$pg_root/socket"
pg_log="$pg_root/logs/pg19-actor-rehearsal.log"
pg_bin="$root/pgsql19/bin"
pg_lib="$root/pgsql19/lib:$HOME/pglocal/usr/lib/x86_64-linux-gnu"
pg_port=55432
archive="$root/sprucegoose-corr7-release.tar.gz"
release="$root/sprucegoose-corr7-release"
client="$root/sprucegoose-corr7-client.py"
env_file="$root/sprucegoose-corr7-pg19.env"
launcher="$root/start-sprucegoose-corr7-pg19.sh"
app_socket_dir="/run/user/$(id -u)/sprucegoose-corr7-pg19"
app_socket="$app_socket_dir/cli.sock"
unit="sprucegoose-corr7-pg19.service"
evidence="$root/corr7-pg19-evidence"
expected_client="d07cc14bff1d4384176f829d9c130a09e82425bc7326fe5370ffc9785ad6b9b9"
run_id="${CORR7_REHEARSAL_RUN_ID:?CORR7_REHEARSAL_RUN_ID is required}"
expected_head="${CORR7_EXPECTED_HEAD:?CORR7_EXPECTED_HEAD is required}"
expected_tree="${CORR7_EXPECTED_TREE:?CORR7_EXPECTED_TREE is required}"
expected_archive="${CORR7_EXPECTED_ARCHIVE_SHA256:?CORR7_EXPECTED_ARCHIVE_SHA256 is required}"
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{7,127}$ ]]
[[ "$expected_head" =~ ^[0-9a-f]{40}$ ]]
[[ "$expected_tree" =~ ^[0-9a-f]{40}$ ]]
[[ "$expected_archive" =~ ^[0-9a-f]{64}$ ]]
script_sha="$(sha256sum "${BASH_SOURCE[0]}" | cut -d' ' -f1)"
pg_running=0
app_running=0
lock_probe_pids=()
probe_hold="${CORR7_REHEARSAL_HOLD_AFTER_APP_START_SECONDS:-0}"
[[ "$probe_hold" =~ ^[0-9]+$ && "$probe_hold" -le 120 ]]

hold_for_signal_probe() {
  local deadline=$((SECONDS + probe_hold))
  while (( SECONDS < deadline )); do
    sleep 0.2
  done
}

cleanup_processes() {
  local pid
  for pid in "${lock_probe_pids[@]}"; do
    kill -TERM "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done
  if [[ "$app_running" == 1 ]]; then
    systemctl --user stop "$unit" >/dev/null 2>&1 || true
  fi
  rm -f -- "$app_socket"
  if [[ "$pg_running" == 1 ]]; then
    LD_LIBRARY_PATH="$pg_lib" "$pg_bin/pg_ctl" -D "$pg_data" -m fast -w stop >/dev/null 2>&1 || true
  fi
}

finalize_exit() {
  local exit_status=$?
  local live_postgresql live_application transient_application
  trap - EXIT
  cleanup_processes

  if [[ "$exit_status" == 0 ]]; then
    live_postgresql="$(systemctl --user show sprucegoose-postgresql.service -p ActiveState --value)"
    live_application="$(systemctl --user show sprucegoose.service -p ActiveState --value)"
    transient_application="$(systemctl --user show "$unit" -p ActiveState --value 2>/dev/null || true)"

    [[ "$live_postgresql" == active ]] || exit 1
    [[ "$live_application" == active ]] || exit 1
    [[ "$transient_application" != active && "$transient_application" != activating ]] || exit 1
    [[ ! -S "$app_socket" ]] || exit 1
    if [[ -d "$pg_data" ]] && LD_LIBRARY_PATH="$pg_lib" "$pg_bin/pg_ctl" -D "$pg_data" status >/dev/null 2>&1; then
      exit 1
    fi
    [[ -f "$evidence/actor-manifest.txt" ]] || exit 1

    {
      printf 'run_id=%s\n' "$run_id"
      printf 'exit_status=0\n'
      printf 'cleanup=PASS\n'
      printf 'transient_postgresql=inactive\n'
      printf 'transient_application=inactive\n'
      printf 'live_postgresql=active\n'
      printf 'live_application=active\n'
      printf 'expected_head=%s\n' "$expected_head"
      printf 'expected_tree=%s\n' "$expected_tree"
      printf 'expected_archive_sha256=%s\n' "$expected_archive"
      printf 'actor_manifest_sha256=%s\n' "$(sha256sum "$evidence/actor-manifest.txt" | cut -d' ' -f1)"
      printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$evidence/completion-status.txt"
    (
      cd "$evidence"
      rm -f -- SHA256SUMS
      sha256sum -- * > SHA256SUMS
      sha256sum -c SHA256SUMS >/dev/null
    )
    chmod 0600 "$evidence"/*
  fi

  exit "$exit_status"
}
trap finalize_exit EXIT
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
"$pgdata_guard" "$pg_data" "$HOME/pgdata" "$actual_live_pgdata" >/dev/null
[[ -x "$pg_bin/postgres" ]]
[[ -f "$archive" && ! -L "$archive" ]]
[[ "$(sha256sum "$archive" | cut -d' ' -f1)" == "$expected_archive" ]]
[[ -x "$client" && ! -L "$client" ]]
[[ "$(sha256sum "$client" | cut -d' ' -f1)" == "$expected_client" ]]
[[ "$(<"$pg_root/run-id")" == "$run_id" ]]
grep -Fqx "run_id=$run_id" "$pg_root/evidence/upgrade-manifest.txt"
(cd "$pg_root/evidence" && sha256sum -c SHA256SUMS >/dev/null)
rm -rf -- "$evidence"
install -d -m 0700 "$evidence" "$app_socket_dir"
rm -f -- "$app_socket"
rm -rf -- "$release"
tar -C "$root" -xzf "$archive"
[[ -x "$release/bin/spruce_goose" ]]
[[ -f "$release/CORR7_PROVENANCE" && ! -L "$release/CORR7_PROVENANCE" ]]
[[ -f "$release/CORR7_COMMIT" && ! -L "$release/CORR7_COMMIT" ]]
[[ "$(git hash-object -t commit --stdin < "$release/CORR7_COMMIT")" == "$expected_head" ]]
grep -Fqx "tree $expected_tree" "$release/CORR7_COMMIT"
grep -Fqx "head=$expected_head" "$release/CORR7_PROVENANCE"
grep -Fqx "tree=$expected_tree" "$release/CORR7_PROVENANCE"
install -m 0600 "$release/CORR7_COMMIT" "$evidence/review-commit"

shopt -s nullglob
migration_files=("$release"/lib/spruce_goose-*/priv/repo/migrations/*.exs)
shopt -u nullglob
[[ "${#migration_files[@]}" == 33 ]]
expected_migration_version_array=()
for migration_file in "${migration_files[@]}"; do
  migration_name="${migration_file##*/}"
  migration_version="${migration_name%%_*}"
  [[ "$migration_version" =~ ^[0-9]{14}$ ]]
  expected_migration_version_array+=("$migration_version")
done
expected_migration_versions="$(printf '%s\n' "${expected_migration_version_array[@]}")"
expected_before_migration_versions="$(printf '%s\n' "${expected_migration_version_array[@]:0:24}")"

clone_url="$(python3 - "$pg_port" "$pg_socket" <<'PY'
import sys
from urllib.parse import urlencode

print(
    f"ecto://postgres@localhost:{sys.argv[1]}/spruce_goose_dev?"
    + urlencode(
        {
            "socket_dir": sys.argv[2],
            "application_name": "corr7_actor_rehearsal",
        }
    )
)
PY
)"
rehearsal_token_signing_secret="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
release_cookie="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
{
  printf 'export DATABASE_URL=%q\n' "$clone_url"
  printf 'export DATABASE_SSL=false\n'
  printf 'export TOKEN_SIGNING_SECRET=%q\n' "$rehearsal_token_signing_secret"
  printf 'export SPRUCE_GOOSE_EXPECTED_GENESIS_ACTOR=recovery-operator\n'
  printf 'export PHX_SERVER=false\n'
  printf 'export SPRUCE_GOOSE_CLI_SERVICE_ENABLED=true\n'
  printf 'export SPRUCE_GOOSE_CLI_SOCKET=%q\n' "$app_socket"
  printf 'export SPRUCE_GOOSE_OBAN_ENABLED=false\n'
  printf 'export OUTBOX_DISPATCHER_ENABLED=false\n'
  printf 'export SPRUCE_GOOSE_MCP_ENABLED=false\n'
  printf 'export LEDGER_RECOVERY_MODE=false\n'
  printf 'export RELEASE_NODE=spruce_goose_corr7_pg19@127.0.0.1\n'
  printf 'export RELEASE_DISTRIBUTION=name\n'
  printf 'export RELEASE_COOKIE=%q\n' "$release_cookie"
} > "$env_file"
chmod 0600 "$env_file"
{
  printf '#!/usr/bin/env bash\nset -Eeuo pipefail\nset -a\n'
  printf '. %q\n' "$env_file"
  printf 'set +a\nexec %q start\n' "$release/bin/spruce_goose"
} > "$launcher"
chmod 0700 "$launcher"

export LD_LIBRARY_PATH="$pg_lib"
pg_running=1
"$pg_bin/pg_ctl" -D "$pg_data" -l "$pg_log" \
  -o "-p $pg_port -k $pg_socket -c listen_addresses=" -w start >/dev/null

before_migrations="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'select count(*) from schema_migrations' -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
before_migration_versions="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'select version::text from schema_migrations order by version' -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
before_tasks="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'select count(*) from workflow_tasks' -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
sample_task_id="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'select task_id from workflow_tasks order by task_id limit 1' -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
[[ -n "$sample_task_id" ]]
[[ "$before_migrations" == 24 ]]
[[ "$before_migration_versions" == "$expected_before_migration_versions" ]]
if "$pg_bin/psql" -X -Atqc "select to_regclass('public.actors') is not null" -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev | grep -Fxq t; then
  printf 'actor table unexpectedly present before migration\n' >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$env_file"
set +a
"$release/bin/spruce_goose" eval 'result=Ecto.Migrator.with_repo(SpruceGoose.Repo, fn repo -> Ecto.Migrator.run(repo, :up, all: true) end); IO.inspect(result, label: "corr7_pg19_migrations")' > "$evidence/migration.log" 2>&1

after_migrations="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'select count(*) from schema_migrations' -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
after_migration_versions="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'select version::text from schema_migrations order by version' -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
after_tasks="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'select count(*) from workflow_tasks' -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
actor_count="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'select count(*) from actors' -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
grant_count="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'select count(*) from actor_grants' -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
[[ "$after_migrations" == 33 ]]
[[ "$after_migration_versions" == "$expected_migration_versions" ]]
[[ "$after_tasks" == "$before_tasks" ]]
[[ "$actor_count" == 0 && "$grant_count" == 0 ]]
relational_edges="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'select count(*) from task_dependencies' -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
graph_edges="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'SELECT count(*) FROM GRAPH_TABLE (sprucegoose_task_dependency_graph MATCH (predecessor IS task)-[edge IS dependency]->(successor IS task) COLUMNS (predecessor.id AS predecessor_id, successor.id AS successor_id))' -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
[[ "$graph_edges" == "$relational_edges" ]]

systemctl --user stop "$unit" 2>/dev/null || true
systemctl --user reset-failed "$unit" 2>/dev/null || true
app_running=1
systemd-run --user --unit="$unit" --collect --property=Type=exec -- "$launcher" >/dev/null
hold_for_signal_probe
ready=0
for _attempt in $(seq 1 80); do
  if [[ -S "$app_socket" ]] \
    && [[ "$(systemctl --user show "$unit" -p ActiveState --value)" == active ]] \
    && SPRUCE_GOOSE_CLI_SOCKET="$app_socket" "$client" version >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.25
done
[[ "$ready" == 1 ]]
"$release/bin/spruce_goose" rpc 'IO.inspect(Application.fetch_env!(:spruce_goose, Oban), label: "oban_config")' > "$evidence/oban-config.txt"
grep -Fq 'queues: false' "$evidence/oban-config.txt"
grep -Fq 'plugins: false' "$evidence/oban-config.txt"

run_client() {
  SPRUCE_GOOSE_CLI_SOCKET="$app_socket" "$client" "$@"
}

set +e
run_client task list --as corr7-unknown > "$evidence/unknown-actor.json" 2>&1
unknown_status=$?
set -e
[[ "$unknown_status" -ne 0 ]]
python3 - "$evidence/unknown-actor.json" <<'PY'
import json,sys
value=json.load(open(sys.argv[1], encoding='utf-8'))
assert not value.get('ok', False) and value.get('error')
PY

run_client actor add recovery-operator --kind human --description 'corr-7 disposable rehearsal' > "$evidence/genesis.json"
run_client whoami --as recovery-operator > "$evidence/operator-whoami.json"
run_client actor add recovery-agent --kind agent --description 'corr-7 delegated rehearsal' --as recovery-operator > "$evidence/agent.json"
run_client grant add recovery-agent --role operator --scope '*' --as recovery-operator > "$evidence/grant.json"
run_client task show "$sample_task_id" --as recovery-agent > "$evidence/agent-task-show.json"
set +e
run_client actor add recovery-intruder --kind agent --as recovery-agent > "$evidence/unauthorized-admin.json" 2>&1
admin_status=$?
set -e
[[ "$admin_status" -ne 0 ]]
python3 - "$evidence/unauthorized-admin.json" <<'PY'
import json,sys
value=json.load(open(sys.argv[1], encoding='utf-8'))
assert not value.get('ok', False) and value.get('error')
PY

actor_count="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'select count(*) from actors' -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
grant_count="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -Atqc 'select count(*) from actor_grants' -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
grant_inventory="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -Atqc "select actor.name || E'\\t' || actor_grant.role::text || E'\\t' || actor_grant.scope || E'\\t' || actor_grant.granted_by from actor_grants actor_grant join actors actor on actor.id=actor_grant.actor_id order by actor.name, actor_grant.role::text, actor_grant.scope, actor_grant.granted_by" -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
expected_grants=$'recovery-agent\toperator\t*\trecovery-operator\nrecovery-operator\tadmin\t*\tgenesis\nrecovery-operator\tapprover\t*\tgenesis\nrecovery-operator\tartifact_verifier\t*\tgenesis\nrecovery-operator\tauthor\t*\tgenesis\nrecovery-operator\toperator\t*\tgenesis\nrecovery-operator\tproposer\t*\tgenesis\nrecovery-operator\treader\t*\tgenesis'
[[ "$actor_count" == 2 ]]
[[ "$grant_count" == 8 ]]
[[ "$grant_inventory" == "$expected_grants" ]]

lock_log="$evidence/registry-write-lock-holder.txt"
mutation_output="$evidence/registry-write-lock-mutation.json"
mutation_done="$evidence/registry-write-lock-mutation.done"
rm -f -- "$lock_log" "$mutation_output" "$mutation_done"
"$pg_bin/psql" -X -v ON_ERROR_STOP=1 -At \
  -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev \
  -c "begin; select pg_advisory_xact_lock(hashtext('sprucegoose:actor-registry-write')); select pg_sleep(5) /* corr7_registry_lock_holder */; commit" \
  > "$lock_log" 2>&1 &
lock_holder_pid=$!
lock_probe_pids+=("$lock_holder_pid")
lock_ready=0
holder_backend_pid=""
for _attempt in $(seq 1 40); do
  holder_backend_pid="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -Atqc "select pid from pg_stat_activity where pid <> pg_backend_pid() and query like '%corr7_registry_lock_holder%' and wait_event = 'PgSleep' order by pid limit 1" -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
  if [[ "$holder_backend_pid" =~ ^[1-9][0-9]*$ ]]; then
    lock_ready=1
    break
  fi
  sleep 0.1
done
[[ "$lock_ready" == 1 ]]
(
  run_client actor disable recovery-agent 'registry lock probe' --as recovery-operator > "$mutation_output"
  printf 'complete\n' > "$mutation_done"
) &
mutation_pid=$!
lock_probe_pids+=("$mutation_pid")
mutation_backend_pid=""
mutation_wait_row=""
for _attempt in $(seq 1 40); do
  mutation_wait_row="$("$pg_bin/psql" -X -v ON_ERROR_STOP=1 -AtF $'\t' -c "select pid, wait_event_type, wait_event, array_to_string(pg_blocking_pids(pid), ',') from pg_stat_activity where wait_event_type = 'Lock' and wait_event = 'advisory' and $holder_backend_pid = any(pg_blocking_pids(pid)) order by pid limit 1" -h "$pg_socket" -p "$pg_port" -U postgres -d spruce_goose_dev)"
  if [[ -n "$mutation_wait_row" ]]; then
    mutation_backend_pid="${mutation_wait_row%%$'\t'*}"
    break
  fi
  [[ ! -e "$mutation_done" ]]
  sleep 0.1
done
[[ "$mutation_backend_pid" =~ ^[1-9][0-9]*$ ]]
printf 'holder_backend_pid=%s\nmutation_backend_pid=%s\nmutation_wait=%s\n' \
  "$holder_backend_pid" "$mutation_backend_pid" "$mutation_wait_row" \
  > "$evidence/registry-write-lock-wait.txt"
wait "$lock_holder_pid"
wait "$mutation_pid"
[[ -f "$mutation_done" ]]
run_client actor enable recovery-agent --as recovery-operator > "$evidence/registry-write-lock-enable.json"
lock_probe_pids=()

systemctl --user stop "$unit"
app_running=0
rm -f -- "$app_socket"
app_running=1
systemd-run --user --unit="$unit" --collect --property=Type=exec -- "$launcher" >/dev/null
hold_for_signal_probe
ready=0
for _attempt in $(seq 1 80); do
  if [[ -S "$app_socket" ]] \
    && [[ "$(systemctl --user show "$unit" -p ActiveState --value)" == active ]] \
    && SPRUCE_GOOSE_CLI_SOCKET="$app_socket" "$client" version >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.25
done
[[ "$ready" == 1 ]]
run_client whoami --as recovery-agent > "$evidence/agent-whoami-after-restart.json"
run_client task show "$sample_task_id" --as recovery-agent > "$evidence/agent-task-show-after-restart.json"

systemctl --user stop "$unit"
app_running=0
rm -f -- "$app_socket"
"$pg_bin/pg_ctl" -D "$pg_data" -m fast -w stop >/dev/null
pg_running=0
actor_cluster_system_identifier="$(LD_LIBRARY_PATH="$pg_lib" "$pg_bin/pg_controldata" "$pg_data" | sed -n 's/^Database system identifier:[[:space:]]*//p')"
{
  printf 'run_id=%s\n' "$run_id"
  printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'expected_head=%s\n' "$expected_head"
  printf 'expected_tree=%s\n' "$expected_tree"
  printf 'actor_script_sha256=%s\n' "$script_sha"
  printf 'archive_sha256=%s\n' "$expected_archive"
  printf 'client_sha256=%s\n' "$expected_client"
  printf 'archive_provenance_sha256=%s\n' "$(sha256sum "$release/CORR7_PROVENANCE" | cut -d' ' -f1)"
  printf 'review_commit_sha256=%s\n' "$(sha256sum "$release/CORR7_COMMIT" | cut -d' ' -f1)"
  printf 'upgrade_manifest_sha256=%s\n' "$(sha256sum "$pg_root/evidence/upgrade-manifest.txt" | cut -d' ' -f1)"
  printf 'cluster_system_identifier=%s\n' "$actor_cluster_system_identifier"
} > "$evidence/actor-manifest.txt"
printf 'migrations=%s->%s\n' "$before_migrations" "$after_migrations"
printf 'tasks=%s->%s\n' "$before_tasks" "$after_tasks"
printf 'graph_edges=%s relational_edges=%s\n' "$graph_edges" "$relational_edges"
printf 'actors=%s actor_grants=%s\n' "$actor_count" "$grant_count"
printf 'authorization_controls=PASS\n'
printf 'registry_write_lock_probe=PASS\n'
printf 'restart_control=PASS\n'
printf 'live_services=active\n'
