#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

required_host=ubuntu-8gb-evergreen
required_opt_in=1
source_name=postgresql-19beta3.tar.gz
source_url="https://ftp.postgresql.org/pub/source/v19beta3/$source_name"
source_sha256=68fb060a0d844c133065372eda19dec726e1280046a8b3405db70f5ebc0fa923
expected_version='PostgreSQL 19beta3'
root="$HOME/papa-pg19beta3-dev"
download="$root/download/$source_name"
source="$root/source/postgresql-19beta3"
build="$root/build"
prefix="$root/install"
pgdata="$root/cluster"
socket_dir="$root/socket"
log_dir="$root/logs"
evidence="$root/evidence"
export BISON_PKGDATADIR="$HOME/papa-pg19beta3-dev/tools/usr/share/bison"
port=55439
running=0

fail() {
  printf 'papa-pg19beta3-dev: %s\n' "$*" >&2
  exit 1
}

stop_cluster() {
  if [[ "$running" == 1 ]]; then
    "$prefix/bin/pg_ctl" -D "$pgdata" -m fast -w stop >/dev/null 2>&1 || true
  fi
}
trap stop_cluster EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ "${PAPA_PG19_DEV_ONLY:-}" == "$required_opt_in" ]] ||
  fail 'PAPA_PG19_DEV_ONLY=1 is required'
[[ "$(hostname)" == "$required_host" ]] || fail 'host is not the Papa development host'
[[ "$root" == "$HOME/papa-pg19beta3-dev" ]] || fail 'unexpected development root'
[[ ! -L "$root" ]] || fail 'development root must not be a symlink'
if [[ -e "$root" ]]; then
  [[ -d "$root" ]] || fail 'development root is not a directory'
  [[ "$(stat -c '%u' "$root")" == "$(id -u)" ]] || fail 'development root has wrong owner'
  mode="$(stat -c '%a' "$root")"
  [[ "$mode" == 700 ]] || fail 'development root must have mode 0700'
fi

for command in curl sha256sum tar make gcc python3 bison flex; do
  command -v "$command" >/dev/null || fail "required command is unavailable: $command"
done

install -d -m 0700 "$root" "$root/download" "$root/source" "$build" "$log_dir" "$evidence"

if [[ ! -f "$download" ]] || [[ "$(sha256sum "$download" | cut -d' ' -f1)" != "$source_sha256" ]]; then
  tmp="$(mktemp "$root/download/.postgresql-19beta3.XXXXXX")"
  curl --fail --location --proto '=https' --tlsv1.2 --output "$tmp" "$source_url"
  [[ "$(sha256sum "$tmp" | cut -d' ' -f1)" == "$source_sha256" ]] ||
    fail 'official source SHA-256 mismatch'
  chmod 0400 "$tmp"
  mv -f -- "$tmp" "$download"
fi
[[ "$(sha256sum "$download" | cut -d' ' -f1)" == "$source_sha256" ]]

rm -rf -- "$source" "$build" "$prefix" "$pgdata" "$socket_dir"
install -d -m 0700 "$root/source" "$build" "$socket_dir"
tar -xzf "$download" -C "$root/source"
[[ -f "$source/configure" && ! -L "$source/configure" ]]

cd "$build"
"$source/configure" \
  --prefix="$prefix" \
  --without-readline \
  --without-icu \
  --without-zstd \
  >"$log_dir/configure.log" 2>&1
make -j2 >"$log_dir/make.log" 2>&1
make install >"$log_dir/install.log" 2>&1

actual_version="$($prefix/bin/postgres --version)"
[[ "$actual_version" == "postgres (PostgreSQL) 19beta3" ]] ||
  fail "unexpected built version: $actual_version"

"$prefix/bin/initdb" \
  --pgdata="$pgdata" \
  --encoding=UTF8 \
  --locale=C.UTF-8 \
  --auth-local=trust \
  --auth-host=reject \
  --username="$(id -un)" \
  >"$log_dir/initdb.log" 2>&1
chmod 0700 "$pgdata" "$socket_dir"

running=1
"$prefix/bin/pg_ctl" -D "$pgdata" -l "$log_dir/postgresql.log" \
  -o "-p $port -k $socket_dir -c listen_addresses=" -w start >"$log_dir/start.log" 2>&1
server_version="$($prefix/bin/psql -X -v ON_ERROR_STOP=1 -At \
  -h "$socket_dir" -p "$port" -U "$(id -un)" -d postgres \
  -c 'show server_version')"
[[ "$server_version" == 19beta3* ]] || fail "unexpected server version: $server_version"
"$prefix/bin/pg_ctl" -D "$pgdata" -m fast -w stop >"$log_dir/stop.log" 2>&1
running=0

cat >"$evidence/never-promote.txt" <<EOF
classification=never-promote
purpose=Papa development only
host=$required_host
source=$source_name
source_sha256=$source_sha256
built_version=$actual_version
server_version=$server_version
network_listener=disabled
production_promotion=prohibited
EOF
chmod 0400 "$evidence/never-promote.txt"
sha256sum "$download" "$prefix/bin/postgres" "$prefix/bin/pg_ctl" "$prefix/bin/psql" \
  "$evidence/never-promote.txt" >"$evidence/SHA256SUMS"
chmod 0400 "$evidence/SHA256SUMS"

printf 'papa_pg19beta3_development=PASS\n'
printf 'version=%s\n' "$server_version"
printf 'classification=never-promote\n'
printf 'root=%s\n' "$root"
