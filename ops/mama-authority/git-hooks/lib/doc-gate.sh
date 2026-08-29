#!/usr/bin/env bash
# Shared doc gate: a change to how something RUNS must not land without its
# documentation being looked at.
#
# Runs in commit-msg, not pre-commit, because it needs the message: the
# override marker lives there. Hook order is pre-commit → prepare-commit-msg
# → commit-msg, and the staged set is still readable at that point.
#
# doc_gate <repo-dir> <message-file>
#   prints a human reason on stdout and returns 1 when the commit must be
#   refused; returns 0 silently otherwise.
#
# Written after two stale-doc findings: a README described a herdr host path
# the containerised app could not reach, and documented a "reviewed upstream
# commit" 52 commits after the release it claimed to describe.

DOC_GATE_OVERRIDE='[docs-checked]'

doc_gate() {
  local repo="${1:-.}" msgfile="${2:-}" staged runtime docs_staged docs

  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0

  # Explicit override — a deliberate, greppable statement that the docs were
  # considered. Never silent, never a flag that ships in a config file.
  if [ -n "$msgfile" ] && [ -f "$msgfile" ] \
     && grep -qF "$DOC_GATE_OVERRIDE" "$msgfile" 2>/dev/null; then
    return 0
  fi

  staged=$(git -C "$repo" diff --cached --name-only 2>/dev/null)
  [ -n "$staged" ] || return 0

  # Files that define runtime behaviour — not every source edit.
  runtime=$(printf '%s\n' "$staged" | grep -E \
    -e '(^|/)config/[^/]+\.(exs|toml|ya?ml)$' \
    -e '\.(container|service|timer|socket)$' \
    -e '(^|/)(Containerfile|Dockerfile)$' \
    -e '(^|/)compose[^/]*\.ya?ml$' \
    -e '(^|/)(pg_hba|postgresql)\.conf$' \
    -e '(^|/)bin/[^/]+\.sh$' \
    || true)
  [ -n "$runtime" ] || return 0

  # Any documentation change at all counts: the gate asks that docs were
  # considered, it cannot judge whether the prose is right.
  docs_staged=$(printf '%s\n' "$staged" | grep -E '\.md$|(^|/)docs/' || true)
  [ -n "$docs_staged" ] && return 0

  docs=""
  for d in README.md CLAUDE.md AGENTS.md; do
    [ -f "$repo/$d" ] && docs="${docs}${docs:+, }$d"
  done
  [ -d "$repo/docs" ] && docs="${docs}${docs:+, }docs/"
  [ -n "$docs" ] || docs="(this repo has no README/docs — consider adding one)"

  printf 'doc gate: refusing this commit — you staged files that define how something runs:\n\n%s\n\nbut no documentation changed. Check whether %s still describes reality;\ndeployment paths, pinned versions/commits and required env vars are what go\nstale. Fix the doc in this same commit rather than filing it for later.\n\nIf the docs are genuinely already correct, say so in the message:\n\n  git commit -m "<your message> %s"\n' \
    "$(printf '%s\n' "$runtime" | sed 's/^/  - /')" "$docs" "$DOC_GATE_OVERRIDE"
  return 1
}
