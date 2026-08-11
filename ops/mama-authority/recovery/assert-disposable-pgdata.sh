#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 3 ]]; then
  printf 'usage: %s CANDIDATE_PGDATA CONFIGURED_LIVE_PGDATA ACTUAL_LIVE_PGDATA\n' "$0" >&2
  exit 64
fi

candidate=$1
configured_live=$2
actual_live=$3

if [[ -L "$candidate" ]]; then
  printf 'candidate PGDATA must not be a symlink: %s\n' "$candidate" >&2
  exit 1
fi

if [[ -e "$candidate" && ! -d "$candidate" ]]; then
  printf 'candidate PGDATA is not a directory: %s\n' "$candidate" >&2
  exit 1
fi

for directory in "$configured_live" "$actual_live"; do
  if [[ ! -d "$directory" ]]; then
    printf 'PGDATA directory does not exist: %s\n' "$directory" >&2
    exit 1
  fi
done

candidate_real="$(realpath -m -- "$candidate")"
configured_live_real="$(realpath -e -- "$configured_live")"
actual_live_real="$(realpath -e -- "$actual_live")"

if [[ "$configured_live_real" != "$actual_live_real" ]]; then
  printf 'configured live PGDATA does not match running postmaster: configured=%s actual=%s\n' \
    "$configured_live_real" "$actual_live_real" >&2
  exit 1
fi

python3 - "$candidate" "$candidate_real" "$actual_live_real" <<'PY'
import os
import stat
import sys

candidate_input, candidate, live = sys.argv[1:]

# Reject every symlink component supplied for the disposable path. realpath(1)
# alone would silently follow a parent alias before the overlap comparison.
current = os.path.sep
for component in os.path.abspath(candidate_input).split(os.path.sep)[1:]:
    current = os.path.join(current, component)
    if not os.path.lexists(current):
        break
    if stat.S_ISLNK(os.lstat(current).st_mode):
        raise SystemExit(f"candidate PGDATA path contains symlink component: {current}")

common = os.path.commonpath([candidate, live])
if common in (candidate, live):
    raise SystemExit(
        f"candidate PGDATA overlaps live PGDATA: candidate={candidate} live={live}"
    )

if os.path.exists(candidate) and os.path.samefile(candidate, live):
    raise SystemExit(
        f"candidate PGDATA overlaps live PGDATA: candidate={candidate} live={live}"
    )

# A bind mount can hide live storage behind an unrelated pathname. This
# procedure intentionally requires disposable and live PGDATA to resolve on
# the same enclosing mount; a separate/bind-mounted rehearsal location must
# be explicitly redesigned rather than accepted implicitly.
def unescape_mount(value):
    return (
        value.replace("\\040", " ")
        .replace("\\011", "\t")
        .replace("\\012", "\n")
        .replace("\\134", "\\")
    )

mounts = []
with open("/proc/self/mountinfo", encoding="utf-8") as stream:
    for line in stream:
        fields = line.rstrip("\n").split(" ")
        mounts.append(os.path.realpath(unescape_mount(fields[4])))

mounts_at_or_below = []
for mount in mounts:
    try:
        if os.path.commonpath([candidate, mount]) == candidate:
            mounts_at_or_below.append(mount)
    except ValueError:
        continue

if mounts_at_or_below:
    raise SystemExit(
        "candidate PGDATA contains mount point at or below destructive root: "
        + ",".join(sorted(set(mounts_at_or_below)))
    )

def enclosing_mount(path):
    matches = [
        mount
        for mount in mounts
        if os.path.commonpath([path, mount]) == mount
    ]
    return max(matches, key=len)

candidate_mount = enclosing_mount(candidate)
live_mount = enclosing_mount(live)
if candidate_mount != live_mount:
    raise SystemExit(
        "candidate and live PGDATA resolve on different mounts: "
        f"candidate_mount={candidate_mount} live_mount={live_mount}"
    )
PY

printf 'candidate_pgdata=%s\nlive_pgdata=%s\npgdata_identity_guard=PASS\n' \
  "$candidate_real" "$actual_live_real"
