# Claude Code hooks for mama

Agent-side enforcement, versioned here for the same reason the systemd
drop-ins alongside are: an artifact that only exists on the box it configures
has no history, no review, and no second copy.

The repo is the source of truth. The host carries a deployed copy.

## The hooks

### `block-secret-commits.sh` — PreToolUse / Bash, **blocking**

Refuses `git commit` when the staged set looks like it carries a credential.

This is the **early half** of the guard, not the authoritative one. Since
2026-08-29 the same rules run as a real git `pre-commit` hook via a global
`core.hooksPath` (`../git-hooks/`), covering every repo and every actor on
the box. This hook exists so an agent gets a readable denial at tool-call
time instead of a commit that dies in the shell — and it **sources
`~/.config/git/hooks/lib/hygiene-scan.sh`**, so the rules live in one file
rather than in two copies that drift. If that library is missing it denies
rather than passing unchecked, so install the git hooks first.

The rules themselves, the reasoning behind their precision, and the
regression list are documented once, in `../git-hooks/README.md`.

**The bypass it used to have.** It resolved the repository only from a
*leading* `cd … &&`, so a compound command routed around it entirely:

    d=$(mktemp -d) && cd "$d" && git add -f .prod.env && git commit -m x

resolved to `$HOME`, not a repo, so the hook exited 0 and the commit landed.
Resolution is wider now — `git -C <dir>`, *any* `cd` in the command, and the
payload's own `cwd`, later winning over earlier — and subcommand detection
survives `git -c user.email=… commit` while ignoring `git log --grep=commit`.

A `cd "$var"` still cannot be resolved statically, and that case is
deliberately allowed to pass *here*: the git hook refuses it without having
to guess where it is. Nothing bypasses both.

### `doc-update-reminder.sh` — PostToolUse / Write|Edit, **advisory**

Fires when a file that defines how something *runs* changes — `config/*.exs`,
`*.container`, `*.service`, `Containerfile`, `pg_hba.conf`, `bin/*.sh` — and
names that repo's actual docs. Silent on ordinary source and on docs
themselves, and once per repo per session so it stays a reminder.

Written after two stale-doc findings: the dashboard README described a herdr
host path the containerised app could not reach, and documented a "reviewed
upstream commit" that was 52 commits *after* the release it claimed to
describe.

### `handoff-capture-reminder.sh` — PostToolUse / Write|Edit, **advisory**

A handoff body is only half a handoff. Item *bodies* live in
`agent-icm/workflows/handoff/`; queue *state* lives in the SpruceGoose inbox,
and `sprucegoose-daily-report` reads the inbox — not the folder. Write a body
without capturing it and the item never reaches the digest: invisible work
that looks filed.

Fires only when no pending capture already references the file (a read-only
DB check, silent if Postgres is unreachable), once per file per session, and
pre-fills the exact `sprucegoose inbox add` line using the body's `# Title`.

It also catches writes to `~/handoff/`, retired 2026-08-29. When that folder
vanished mid-session a handoff item landed loose in `$HOME` and went unnoticed
until a later `cd` failed.

## Install on the host

The git hooks are a prerequisite — `block-secret-commits.sh` sources their
shared library:

    ops/mama-authority/git-hooks/install.sh
    install -m 755 ops/mama-authority/claude-hooks/*.sh ~/.claude/hooks/

and register them in `~/.claude/settings.json`:

    "hooks": {
      "PreToolUse":  [{"matcher": "Bash",
        "hooks": [{"type": "command",
          "command": "/home/admin-papa/.claude/hooks/block-secret-commits.sh",
          "timeout": 15}]}],
      "PostToolUse": [{"matcher": "Write|Edit",
        "hooks": [
          {"type": "command",
           "command": "/home/admin-papa/.claude/hooks/doc-update-reminder.sh",
           "timeout": 10},
          {"type": "command",
           "command": "/home/admin-papa/.claude/hooks/handoff-capture-reminder.sh",
           "timeout": 15}]}]
    }

**Hooks added mid-session do not take effect until config reloads** — open
`/hooks` once, or restart. Verified the hard way: after writing the config,
a deliberate commit of a staged `.prod.env` still succeeded. Always prove a
new hook fires before believing it protects you. The git hooks have no such
problem: they take effect on the next commit, in every shell.

## Testing a change

`jq` is required. Pipe a synthetic payload straight in:

    echo '{"tool_input":{"command":"cd /repo && git commit -m x"}}' \
      | ops/mama-authority/claude-hooks/block-secret-commits.sh

No output means allow; JSON with `permissionDecision: "deny"` means blocked.
The deny/allow regression list is in `../git-hooks/README.md` — one list, since
both hooks run the same library. What is specific to *this* hook is repository
resolution, and each of these must DENY on a repo with `.prod.env` staged:

    {"tool_input":{"command":"git commit -m x"},"cwd":"<repo>"}
    {"tool_input":{"command":"git -c user.email=t@t commit -m x"},"cwd":"<repo>"}
    {"tool_input":{"command":"echo hi && cd <repo> && git commit -m x"}}
    {"tool_input":{"command":"git -C <repo> commit -m x"}}

while these must stay silent:

    {"tool_input":{"command":"git log --grep=commit"},"cwd":"<repo>"}
    {"tool_input":{"command":"d=$(mktemp -d) && cd \"$d\" && git commit -m x"}}
