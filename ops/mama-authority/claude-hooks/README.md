# Claude Code hooks for mama

Agent-side enforcement, versioned here for the same reason the systemd
drop-ins alongside are: an artifact that only exists on the box it configures
has no history, no review, and no second copy.

The repo is the source of truth. The host carries a deployed copy.

## The hooks

### `block-secret-commits.sh` — PreToolUse / Bash, **blocking**

Refuses `git commit` when the staged set looks like it carries a credential.

Written after a near-miss: `accountabot-dashboard-src/.prod.env` (live
production secrets, mode 0600) was not covered by that repo's `.gitignore`,
so a `git add -A` during its first import would have committed it
permanently.

Two checks, both deliberately high-precision:

* **Filenames that are secrets by convention** — `*.env`, `*.pem`, `*.key`,
  `id_rsa`, `.netrc`, `.git-credentials`. `.env.example` / `.sample` /
  `.template` are allowed.
* **Real credential formats in added lines** — `BEGIN … PRIVATE KEY`,
  `AKIA…`, `ghp_…`, `sk-ant-…`, `xox[baprs]-…`, and URLs carrying an embedded
  password.

Matched values are **truncated** in the denial text: the guard must not be
the thing that echoes a secret into a transcript.

Precision matters more than recall here. A manual content scan during that
same import flagged Phoenix's `dev-only-secret-key-base-…` placeholders, the
app's own redaction regexes, and `System.fetch_env!("SECRET_KEY_BASE")`. A
guard that cries wolf gets switched off, so this matches credential *formats*
and known *filenames*, never the word "secret". All four of those cases are
covered by tests below and must keep passing.

It matches `git commit` as a substring, not via a `Bash(git commit:*)`
prefilter, so `cd repo && git commit …` is caught too, and it honours a
leading `cd <dir> &&` so the check runs against the right repository.

### `doc-update-reminder.sh` — PostToolUse / Write|Edit, **advisory**

Fires when a file that defines how something *runs* changes — `config/*.exs`,
`*.container`, `*.service`, `Containerfile`, `pg_hba.conf`, `bin/*.sh` — and
names that repo's actual docs. Silent on ordinary source and on docs
themselves, and once per repo per session so it stays a reminder.

Written after two stale-doc findings: the dashboard README described a herdr
host path the containerised app could not reach, and documented a "reviewed
upstream commit" that was 52 commits *after* the release it claimed to
describe.

## Install on the host

    install -m 755 ops/mama-authority/claude-hooks/*.sh ~/.claude/hooks/

and register them in `~/.claude/settings.json`:

    "hooks": {
      "PreToolUse":  [{"matcher": "Bash",
        "hooks": [{"type": "command",
          "command": "/home/admin-papa/.claude/hooks/block-secret-commits.sh",
          "timeout": 15}]}],
      "PostToolUse": [{"matcher": "Write|Edit",
        "hooks": [{"type": "command",
          "command": "/home/admin-papa/.claude/hooks/doc-update-reminder.sh",
          "timeout": 10}]}]
    }

**Hooks added mid-session do not take effect until config reloads** — open
`/hooks` once, or restart. Verified the hard way: after writing the config,
a deliberate commit of a staged `.prod.env` still succeeded. Always prove a
new hook fires before believing it protects you.

## Testing a change

`jq` is required. Pipe a synthetic payload straight in:

    echo '{"tool_input":{"command":"cd /repo && git commit -m x"}}' \
      | ops/mama-authority/claude-hooks/block-secret-commits.sh

No output means allow; JSON with `permissionDecision: "deny"` means blocked.
Regressions to re-check after any edit — these must DENY:

    .prod.env staged · AKIA<16> · BEGIN RSA PRIVATE KEY · postgres://u:pw@h/db

and these must ALLOW:

    .env.example · dev-only-secret-key-base-… · a redaction regex source line
    · System.fetch_env!("SECRET_KEY_BASE") · short fake fixtures · a URL with
    no password (ecto://postgres@127.0.0.1/db)
