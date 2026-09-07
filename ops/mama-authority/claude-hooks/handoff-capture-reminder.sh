#!/usr/bin/env bash
# PostToolUse/Write|Edit — a handoff body is only half a handoff.
#
# The queue is split on purpose: item BODIES live in
# agent-icm/workflows/handoff/, queue STATE lives in the SpruceGoose inbox,
# and sprucegoose-daily-report reads the inbox — not the folder. Write a body
# without capturing it and the item never reaches the digest: invisible work
# that looks filed.
#
# Also catches writes to ~/handoff/, retired 2026-08-29. A file written there
# goes nowhere; when the directory vanished mid-session a handoff item landed
# loose in $HOME instead, unnoticed until a later `cd` failed.
set -uo pipefail

payload=$(cat)
f=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_response.filePath // ""' 2>/dev/null)
sid=$(printf '%s' "$payload" | jq -r '.session_id // "nosession"' 2>/dev/null)
[ -n "$f" ] || exit 0

emit() { jq -nc --arg c "$1" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'; exit 0; }

# --- retired path -------------------------------------------------------
case "$f" in
  "$HOME"/handoff/*)
    emit "STOP: ~/handoff/ is retired (2026-08-29) and is not read by anything. Handoff bodies belong in agent-icm/workflows/handoff/ — authored on papa, since mama's checkout is pinned and never authored on — and the queue entry goes in the SpruceGoose inbox. Move this file and add a capture, or it is invisible work."
    ;;
esac

# --- a real handoff body ------------------------------------------------
case "$f" in
  */workflows/handoff/*.md) ;;
  *) exit 0 ;;
esac
base=$(basename "$f")
case "$base" in README.md) exit 0 ;; esac

# Once per file per session.
stamp="/tmp/claude-handoffhook-${sid}-${base//[^a-zA-Z0-9]/_}"
[ -e "$stamp" ] && exit 0

title=$(grep -m1 '^# ' "$f" 2>/dev/null | sed 's/^# //')
[ -n "$title" ] || title="(no '# Title' line — the daily digest uses it, so add one)"

# Only nag if it is not already queued. Read-only DB check; stay silent if
# Postgres is unreachable rather than guessing.
queued=""
# Postgres sits at a different prefix on each host -- ~/pglocal19 on mama,
# ~/data/pglocal19 on papa -- and this file is deployed to both. Resolve it
# rather than hardcoding one, or the -x test fails on the other host and the
# dedupe check silently degrades into nagging on every capture.
pgprefix=""
for _p in /home/admin-papa/pglocal19 /home/admin-papa/data/pglocal19; do
  [ -x "$_p/bin/psql" ] && { pgprefix="$_p"; break; }
done
if [ -n "$pgprefix" ]; then
  queued=$(LD_LIBRARY_PATH="$pgprefix/lib" \
    "$pgprefix/bin/psql" -h /tmp -U postgres -d spruce_goose_dev -tAc \
    "select count(*) from inbox_items where state='pending' and body like '%${base//\'/\'\'}%'" 2>/dev/null)
fi
[ "${queued:-0}" != "0" ] && exit 0

: > "$stamp"
emit "Handoff body written ($base) but no pending inbox capture references it. Bodies and queue state are separate systems — the daily digest reads the inbox, not the folder, so this item will not surface until it is captured:

  sprucegoose inbox add \"[handoff] ${title} (source: agent-icm/workflows/handoff/${base})\" --as <actor>

Use a dedicated actor, not a human's name. Also remember bodies are authored on papa and promoted to mama by tag."
