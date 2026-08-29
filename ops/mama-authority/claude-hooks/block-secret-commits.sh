#!/usr/bin/env bash
# PreToolUse/Bash — refuse `git commit` when the staged set looks like it
# carries a credential.
#
# This is the EARLY half of the guard, not the authoritative one. Since
# 2026-08-29 the same rules run as a real git pre-commit hook via a global
# `core.hooksPath`, which covers every repo and every actor on the box. This
# hook exists so an agent gets a readable denial at tool-call time instead of
# a commit that dies in the shell — and so the rules live in one file, shared
# with the git hook rather than copied.
#
# The original version resolved the repository only from a LEADING `cd … &&`,
# which a compound command routed straight around:
#
#   d=$(mktemp -d) && cd "$d" && git add -f .prod.env && git commit -m x
#
# resolved to $HOME (not a repo), so the hook exited 0 and the commit landed.
# Resolution is wider now — `git -C`, any `cd` in the command, the payload's
# own cwd — but a `cd "$var"` still cannot be resolved statically. That case
# is deliberately allowed to pass HERE and refused by the git hook, which
# does not have to guess where it is.
set -uo pipefail

payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)
cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)

# Is `commit` actually the git subcommand? A plain substring test missed
# `git -c user.email=… commit`, and matching bare "commit" would fire on
# `git log --grep=commit`.
printf '%s' "$cmd" | grep -qE \
  '(^|[;&|]|\$\()[[:space:]]*git([[:space:]]+(-[cC][[:space:]]+[^[:space:]]+|--[a-z-]+(=[^[:space:]]+)?|-[a-zA-Z]))*[[:space:]]+commit([[:space:]]|$)' \
  || exit 0

deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

lib="$HOME/.config/git/hooks/lib/hygiene-scan.sh"
if [ ! -r "$lib" ]; then
  deny "git hygiene hook: the shared guard library is missing at $lib, so the
staged set cannot be checked. Reinstall it from sprucegoose
ops/mama-authority/git-hooks/ (install.sh) before committing."
fi
# shellcheck source=../git-hooks/lib/hygiene-scan.sh
. "$lib"

# --- where is the repo? -------------------------------------------------
# Later wins: an explicit `git -C` beats a `cd`, a `cd` beats the session cwd.
repo=""
[ -n "$cwd" ] && [ -d "$cwd" ] && repo="$cwd"

while read -r d; do
  [ -n "$d" ] || continue
  case "$d" in *'$'*|*'`'*|*'*'*) continue ;; esac   # not statically knowable
  d=${d%\"}; d=${d#\"}; d=${d%\'}; d=${d#\'}
  case "$d" in "~"|"~/"*) d="$HOME${d#\~}" ;; esac
  [ -d "$d" ] && repo="$d"
done < <(printf '%s' "$cmd" | grep -oE '(^|[;&|]|&&)[[:space:]]*cd[[:space:]]+[^;&|]+' \
         | sed -E 's/.*cd[[:space:]]+//; s/[[:space:]]+$//')

while read -r d; do
  [ -n "$d" ] || continue
  case "$d" in *'$'*|*'`'*) continue ;; esac
  d=${d%\"}; d=${d#\"}; d=${d%\'}; d=${d#\'}
  [ -d "$d" ] && repo="$d"
done < <(printf '%s' "$cmd" | grep -oE '\bgit[[:space:]]+-C[[:space:]]+[^[:space:]]+' \
         | sed -E 's/.*-C[[:space:]]+//')

[ -n "$repo" ] || exit 0                       # nothing to judge from here
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || exit 0

if ! reason=$(hygiene_scan "$repo"); then
  deny "$reason"
fi

exit 0
