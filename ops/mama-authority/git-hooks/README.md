# Box-wide git hooks for mama

Two rules that were previously agent-side only, moved to where git itself
enforces them: **no credential in a commit**, and **no change to how
something runs without its documentation being looked at**.

The repo is the source of truth. The host carries a deployed copy at
`~/.config/git/hooks`, pointed at by a global `core.hooksPath`.

## Why here and not only in the Claude Code hook

The Claude hook covers commits *Claude* makes. Everything else on this box —
your own shell, OpenClaw, Codex, Pi, a script — was unguarded. Worse, the
Claude hook resolved the repository only from a **leading** `cd … &&`, so a
compound command routed straight around it:

    d=$(mktemp -d) && cd "$d" && git add -f .prod.env && git commit -m x

resolved to `$HOME`, which is not a repo, so the hook exited 0 and the commit
landed. Proven on 2026-08-29, not assumed. A guard you can step over by
reordering a shell line is not a guard.

`core.hooksPath` has no such blind spot: git runs the hook from inside the
repository, so there is nothing to infer.

## Chaining — the part that makes this safe

**`core.hooksPath` replaces a repository's hooks directory. It does not merge
with it.** Setting it naively would have silently disabled every existing
hook on the box, starting with the `post-receive` on `~/agent-icm.git` that
mirrors `main` and its tags to Forgejo — publication would have stopped, and
the failure would have looked like nothing at all.

So every standard hook name in this directory is a symlink to `_chain`, which
execs `$GIT_DIR/hooks/<name>` when the repository has one, passing argv,
stdin and exit status straight through. `pre-commit` and `commit-msg` run
their own check first and then chain the same way. A repo-local hook that
rejects still rejects.

Deliberately **not** stubbed: `reference-transaction`, `pre-auto-gc`,
`fsmonitor-watchman`. They fire often enough that a subprocess per invocation
is a real cost, and nothing on this box defines them. Add a symlink if that
changes.

`install.sh` also pins `core.hooksPath` locally inside `~/agent-icm.git` as
belt and braces, so a future edit to the global path cannot take Forgejo
publication down.

## The checks

### `pre-commit` → `lib/hygiene-scan.sh` — blocking

Refuses a commit whose staged set carries a credential. Two checks, both
deliberately high-precision:

* **Filenames that are secrets by convention** — `*.env`, `*.pem`, `*.key`,
  `id_rsa`, `.netrc`, `.git-credentials`. `.env.example` / `.sample` /
  `.template` / `.dist` are allowed.
* **Real credential formats in added lines** — `BEGIN … PRIVATE KEY`,
  `AKIA…`, `ghp_…`, `sk-ant-…`, `xox[baprs]-…`, and URLs carrying an embedded
  password.

Matched values are truncated to 12 characters in the denial: the guard must
not be the thing that echoes a secret into a transcript. (It truncated to 24
until 2026-08-29, which was long enough to print a whole `AKIA` key.)

Precision matters more than recall. A manual content scan during the
`accountabot-dashboard-src` import flagged Phoenix's
`dev-only-secret-key-base-…` placeholders, the app's own redaction regexes,
and `System.fetch_env!("SECRET_KEY_BASE")`. A guard that cries wolf gets
switched off, so this matches credential *formats* and known *filenames*,
never the word "secret".

### `commit-msg` → `lib/doc-gate.sh` — blocking, overridable

Refuses a commit that stages a file defining how something runs —
`config/*.exs|toml|yaml`, `*.container`, `*.service`, `*.timer`, `*.socket`,
`Containerfile`, `compose*.yml`, `pg_hba.conf`, `postgresql.conf`,
`bin/*.sh` — while staging no documentation at all. The denial names the
repo's actual docs.

Any staged `*.md` or anything under `docs/` satisfies it. The gate asks that
the docs were *considered*; it cannot judge whether the prose is right.

Override by putting `[docs-checked]` in the commit message. That is
deliberately a statement in the permanent record and greppable after the
fact, not a flag in a config file that quietly stays on:

    git commit -m "bind distribution to loopback [docs-checked]"

It lives in `commit-msg` rather than `pre-commit` because it needs the
message, and hook order is pre-commit → prepare-commit-msg → commit-msg. The
staged set is still readable there.

Written after two stale-doc findings: the dashboard README described a herdr
host path the containerised app could not reach, and documented a "reviewed
upstream commit" 52 commits *after* the release it claimed to describe.

## Install

    ops/mama-authority/git-hooks/install.sh          # dest defaults to ~/.config/git/hooks

Idempotent. It copies the scripts and `lib/`, recreates the passthrough
symlinks, sets the global `core.hooksPath`, and pins `~/agent-icm.git` to its
own hooks directory.

`lib/hygiene-scan.sh` is also sourced by the Claude Code hook in
`../claude-hooks/`, so the rules exist once. Installing the git hooks is a
prerequisite for that hook — it refuses rather than passing unchecked if the
library is missing.

## What this does not cover

`git commit --no-verify` skips both, by design — the escape hatch is
deliberate and visible. Hooks are per-user config, so this protects commits
made as `admin-papa`; a commit made inside a container as another user is not
covered.

## Testing a change

`jq` is required only by the Claude hook, not by these. Point a scratch repo
at the source tree and drive real commits:

    T=$(mktemp -d); git init -q "$T"; git -C "$T" config core.hooksPath \
      "$PWD/ops/mama-authority/git-hooks"

These must **DENY**:

    .prod.env staged · AKIA<16> · BEGIN RSA PRIVATE KEY · postgres://u:pw@h/db
    config/runtime.exs staged with no doc staged

These must **ALLOW**:

    .env.example · dev-only-secret-key-base-… · a redaction regex source line
    · System.fetch_env!("SECRET_KEY_BASE") · a URL with no password
      (ecto://postgres@127.0.0.1/db) · ordinary source with no doc change
    · config/runtime.exs + any .md staged together
    · config/runtime.exs with [docs-checked] in the message

And chaining must hold: a repo-local `pre-commit` still runs, and still
rejects when it exits nonzero; a bare repo's `post-receive` still receives
its refs on stdin.
