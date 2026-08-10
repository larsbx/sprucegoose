#!/usr/bin/env bash
set -euo pipefail

base="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unit="$base/sprucegoose-remote-client.service"
marker="${SPRUCE_GOOSE_AUTHORITY_MARKER:-$HOME/.config/sprucegoose/authority-host}"

grep -Fq 'RuntimeDirectoryMode=0700' "$unit"
grep -Fq 'BatchMode=yes' "$unit"
grep -Fq 'ExitOnForwardFailure=yes' "$unit"
grep -Fq 'StreamLocalBindUnlink=yes' "$unit"
grep -Fq -- '-L %t/sprucegoose/cli.sock:%t/sprucegoose/cli.sock mama' "$unit"
grep -Fq 'Restart=on-failure' "$unit"
grep -Fq 'NoNewPrivileges=true' "$unit"
grep -Fq 'ProtectSystem=strict' "$unit"
grep -Fq 'sop_preflight' "$base/../../sprucegoose"

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
