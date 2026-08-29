#!/usr/bin/env bash
# PostToolUse/Write|Edit — when a file that defines how something RUNS is
# changed, point at that repo's docs.
#
# Advisory, never blocking. Written after two stale-doc findings: the
# dashboard README described a herdr host path the containerised app could
# not reach, and it documented a "reviewed upstream commit" that was 52
# commits after the release it claimed to describe.
#
# Fires at most once per repo per session so it stays a reminder, not a nag.
set -uo pipefail

payload=$(cat)
f=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_response.filePath // ""' 2>/dev/null)
sid=$(printf '%s' "$payload" | jq -r '.session_id // "nosession"' 2>/dev/null)
[ -n "$f" ] && [ -e "$f" ] || exit 0

base=$(basename "$f")

# Never remind about editing a doc with a doc reminder.
case "$base" in README.md|CLAUDE.md|AGENTS.md|*.md) exit 0 ;; esac

# Only files that define runtime behaviour — not every source edit.
case "$f" in
  */config/*.exs|*/config/*.toml|*/config/*.yaml|*/config/*.yml) ;;
  *.container|*.service|*.timer|*.socket)                        ;;
  */Containerfile|*/Dockerfile|*/compose*.yml)                   ;;
  *pg_hba.conf|*postgresql.conf)                                 ;;
  */bin/*.sh|*/.local/bin/*)                                     ;;
  *) exit 0 ;;
esac

repo=$(git -C "$(dirname "$f")" rev-parse --show-toplevel 2>/dev/null) || exit 0
[ -n "$repo" ] || exit 0

# Once per repo per session.
stamp="/tmp/claude-dochook-${sid}-$(printf '%s' "$repo" | tr -c 'a-zA-Z0-9' '_')"
[ -e "$stamp" ] && exit 0

docs=""
for d in README.md CLAUDE.md AGENTS.md; do
  [ -f "$repo/$d" ] && docs="${docs}${docs:+, }$d"
done
[ -d "$repo/docs" ] && docs="${docs}${docs:+, }docs/"
[ -n "$docs" ] || exit 0

: > "$stamp"
jq -nc --arg f "${f#$repo/}" --arg d "$docs" --arg r "$(basename "$repo")" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:
    ("Doc-hygiene reminder (once per repo per session): you changed \($f) in \($r), which defines how something runs. Check whether \($d) still describes reality — deployment paths, pinned versions/commits, and required env vars are what go stale. If a doc is now wrong, fix it in the same change rather than filing it for later.")}}'
exit 0
