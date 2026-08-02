#!/usr/bin/env bash
set -euo pipefail

base="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unit="$base/sprucegoose-remote-client.service"

grep -Fq 'RuntimeDirectoryMode=0700' "$unit"
grep -Fq 'BatchMode=yes' "$unit"
grep -Fq 'ExitOnForwardFailure=yes' "$unit"
grep -Fq 'StreamLocalBindUnlink=yes' "$unit"
grep -Fq -- '-L %t/sprucegoose/cli.sock:%t/sprucegoose/cli.sock mama' "$unit"
grep -Fq 'Restart=on-failure' "$unit"
grep -Fq 'NoNewPrivileges=true' "$unit"
grep -Fq 'ProtectSystem=strict' "$unit"

if systemctl --user is-active --quiet sprucegoose-remote-client.service; then
  test -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/sprucegoose/cli.sock"
  output="$(timeout -k 1s 5s "$base/../../sprucegoose" version)"
  python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["ok"] and value["version"]' <<<"$output"
fi

echo 'mama authority bridge contract: PASS'
