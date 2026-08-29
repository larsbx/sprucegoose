#!/usr/bin/env bash
# PreToolUse/Bash — refuse `git commit` when the staged set looks like it
# carries a credential.
#
# Written after a near-miss: accountabot-dashboard-src/.prod.env (live
# production secrets, mode 0600) was NOT covered by that repo's .gitignore,
# so `git add -A` would have committed it permanently on the first import.
#
# Deliberately high-precision. An earlier content scan in that session flagged
# Phoenix's `dev-only-secret-key-base-...` placeholders and the app's own
# redaction regexes — a guard that cries wolf gets switched off, so this
# matches real credential FORMATS and known-secret FILENAMES only.
set -uo pipefail

payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Fast exit: not a commit. Substring match so `cd x && git commit` is caught,
# which a `Bash(git commit:*)` prefilter would miss.
case "$cmd" in *"git commit"*) ;; *) exit 0 ;; esac

# Honour a leading `cd <dir> &&` so the check runs in the right repo.
workdir=$(printf '%s' "$cmd" | sed -nE "s/^[[:space:]]*cd[[:space:]]+([^&;|]+)[[:space:]]*&&.*/\1/p" | tr -d "\"'" | xargs 2>/dev/null)
[ -n "${workdir:-}" ] && [ -d "$workdir" ] && cd "$workdir" 2>/dev/null

git rev-parse --git-dir >/dev/null 2>&1 || exit 0   # not a repo: nothing to judge

staged=$(git diff --cached --name-only 2>/dev/null)
[ -n "$staged" ] || exit 0

deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# --- 1. filenames that are secrets by convention -------------------------
# Example files are explicitly fine.
bad_names=$(printf '%s\n' "$staged" \
  | grep -vE '\.(example|sample|template|dist)$' \
  | grep -E '(^|/)\.?[^/]*\.env$|(^|/)\.env\.|\.pem$|\.p12$|\.pfx$|\.key$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|(^|/)\.netrc$|(^|/)\.git-credentials$' \
  || true)
if [ -n "$bad_names" ]; then
  deny "git hygiene hook: refusing this commit — the staged set contains files that hold credentials by convention:

$(printf '%s\n' "$bad_names" | sed 's/^/  - /')

Add them to .gitignore and 'git restore --staged' them. If one is genuinely
a template, name it .env.example (that suffix is allowed).
Verify with: git check-ignore -v <file>"
fi

# --- 2. real credential formats in ADDED lines ---------------------------
hits=$(git diff --cached -U0 2>/dev/null | grep '^+' | grep -oEm5 \
  -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
  -e 'AKIA[0-9A-Z]{16}' \
  -e 'ghp_[A-Za-z0-9]{36}' \
  -e 'sk-ant-[A-Za-z0-9_-]{40,}' \
  -e 'xox[baprs]-[0-9A-Za-z-]{12,}' \
  -e '://[^:@/[:space:]]+:[^@/[:space:]]{8,}@' \
  | sort -u | head -5 || true)
if [ -n "$hits" ]; then
  masked=$(printf '%s\n' "$hits" | cut -c1-24 | sed 's/$/…/; s/^/  - /')
  deny "git hygiene hook: refusing this commit — the staged diff contains something shaped like a live credential:

$masked

Values are truncated on purpose. Remove them, use an env var, and re-stage.
Inspect with: git diff --cached"
fi

exit 0
