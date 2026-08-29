#!/usr/bin/env bash
# Shared staged-set credential scan.
#
# Sourced by both enforcement points so there is exactly one copy of the
# rules: the git pre-commit hook (authoritative, covers every actor on the
# box) and the Claude Code PreToolUse hook (advisory-early, nicer denial).
#
# hygiene_scan <repo-dir>
#   prints a human reason on stdout and returns 1 when the commit must be
#   refused; returns 0 silently otherwise.
#
# Deliberately high-precision. An earlier content scan flagged Phoenix's
# `dev-only-secret-key-base-...` placeholders and an app's own redaction
# regexes — a guard that cries wolf gets switched off, so this matches real
# credential FORMATS and known-secret FILENAMES only.

hygiene_scan() {
  local repo="${1:-.}" staged bad_names hits masked

  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 0

  staged=$(git -C "$repo" diff --cached --name-only 2>/dev/null)
  [ -n "$staged" ] || return 0

  # --- 1. filenames that are secrets by convention ----------------------
  # Example/template files are explicitly fine.
  bad_names=$(printf '%s\n' "$staged" \
    | grep -vE '\.(example|sample|template|dist)$' \
    | grep -E '(^|/)\.?[^/]*\.env$|(^|/)\.env\.|\.pem$|\.p12$|\.pfx$|\.key$|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|(^|/)\.netrc$|(^|/)\.git-credentials$' \
    || true)
  if [ -n "$bad_names" ]; then
    printf 'git hygiene: refusing this commit — the staged set contains files that hold credentials by convention:\n\n%s\n\nAdd them to .gitignore and `git restore --staged` them. If one is genuinely\na template, name it .env.example (that suffix is allowed).\nVerify with: git check-ignore -v <file>\n' \
      "$(printf '%s\n' "$bad_names" | sed 's/^/  - /')"
    return 1
  fi

  # --- 2. real credential formats in ADDED lines ------------------------
  hits=$(git -C "$repo" diff --cached -U0 2>/dev/null | grep '^+' | grep -oEm5 \
    -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
    -e 'AKIA[0-9A-Z]{16}' \
    -e 'ghp_[A-Za-z0-9]{36}' \
    -e 'sk-ant-[A-Za-z0-9_-]{40,}' \
    -e 'xox[baprs]-[0-9A-Za-z-]{12,}' \
    -e '://[^:@/[:space:]]+:[^@/[:space:]]{8,}@' \
    | sort -u | head -5 || true)
  if [ -n "$hits" ]; then
    masked=$(printf '%s\n' "$hits" | cut -c1-12 | sed 's/$/…/; s/^/  - /')
    printf 'git hygiene: refusing this commit — the staged diff contains something shaped like a live credential:\n\n%s\n\nValues are truncated on purpose. Remove them, use an env var, and re-stage.\nInspect with: git diff --cached\n' \
      "$masked"
    return 1
  fi

  return 0
}
