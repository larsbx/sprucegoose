#!/usr/bin/env bash
set -euo pipefail

base="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unit="$base/sprucegoose-remote-client.service"
executor_manifest="$base/derivation-executor.toml"
executor_dropin="$base/sprucegoose.service.d/20-derivation-executor.conf"
marker="${SPRUCE_GOOSE_AUTHORITY_MARKER:-$HOME/.config/sprucegoose/authority-host}"

test -f "$executor_manifest"
grep -Fxq 'schema = "sprucegoose-derivation-executor-v1"' "$executor_manifest"
grep -Fxq 'actor = "sprucegoose-derivation-v1"' "$executor_manifest"
grep -Fxq 'queue = "derivations"' "$executor_manifest"
grep -Fxq 'actions = ["verify_artifact"]' "$executor_manifest"
grep -Fxq 'job_arguments = ["permit_id"]' "$executor_manifest"
! grep -Eqi 'command|shell|script|test|build_release' "$executor_manifest"

test -f "$executor_dropin"
grep -Fxq '[Service]' "$executor_dropin"
grep -Fxq 'Environment=SPRUCE_GOOSE_DERIVATION_EXECUTOR_ACTOR=sprucegoose-derivation-v1' "$executor_dropin"
grep -Fxq 'Environment=SPRUCE_GOOSE_OBAN_ENABLED=true' "$executor_dropin"
grep -Fxq 'ExecStart=' "$executor_dropin"
grep -Fxq 'ExecStart=/usr/bin/env SPRUCE_GOOSE_OBAN_ENABLED=true SPRUCE_GOOSE_DERIVATION_EXECUTOR_ACTOR=sprucegoose-derivation-v1 /home/admin-papa/sprucegoose-rel/bin/spruce_goose start' "$executor_dropin"

grep -Fq 'RuntimeDirectoryMode=0700' "$unit"
grep -Fq 'BatchMode=yes' "$unit"
grep -Fq 'ExitOnForwardFailure=yes' "$unit"
grep -Fq 'StreamLocalBindUnlink=yes' "$unit"
grep -Fq -- '-L %t/sprucegoose/cli.sock:%t/sprucegoose/cli.sock mama' "$unit"
grep -Fq 'Restart=on-failure' "$unit"
grep -Fq 'NoNewPrivileges=true' "$unit"
grep -Fq 'ProtectSystem=strict' "$unit"
grep -Fq 'sop_preflight' "$base/../../sprucegoose"
grep -Fq 'path: System.get_env("SPRUCE_GOOSE_ESCRIPT_PATH", "sprucegoose-direct")' \
  "$base/../../mix.exs"

test -r "$marker"
test "$(tr -d '[:space:]' < "$marker")" = mama

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
cat >"$tmp/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%064d  Systemwide SOP.md\n' 0
EOF
chmod +x "$tmp/ssh"
if PATH="$tmp:$PATH" python3 "$base/../../scripts/sprucegoose-client.py" task start probe \
  >"$tmp/out" 2>&1; then
  echo "SOP drift preflight unexpectedly allowed task start" >&2
  exit 1
fi
grep -Fq 'Systemwide SOP drift between Evergreen and Mama' "$tmp/out"

if systemctl --user is-active --quiet sprucegoose-remote-client.service; then
  test -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sprucegoose/cli.sock"
  output="$(timeout -k 1s 5s "$base/../../sprucegoose" version)"
  python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["ok"] and value["version"]' <<<"$output"
fi

echo 'mama authority bridge contract: PASS'
