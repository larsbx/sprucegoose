# Audit — SpruceGoose repository custody and publication state

- **Date:** 2026-09-07
- **Host:** `ubuntu-8gb-evergreen` (papa)
- **Auditor:** Claude Code session `session_01Ld1WkfS3qtKQZFq7uHF9h9`, acting as `handoff-sync`
- **Repository:** `/home/admin-papa/governance/sprucegoose`
- **Branch / HEAD:** `rebase/ops-claude-hooks` @ `748e2d13b8e4386cf9e7b4757f572fb6980a3c17` (2026-09-07 07:18)
- **Remotes:** `forgejo` → `https://ubuntu-8gb-hil-1.tail2188e6.ts.net:8448/root/sprucegoose.git`; `origin` → `https://github.com/larsbx/sprucegoose.git`

## Scope

Repository custody, worktree integrity and publication state across papa and mama.
Read-only. No code, dependency, security or test review was performed, and nothing was
changed on either host.

This supersedes the source metadata of the earlier bundle in this session
(`20260907T200232Z-sprucegoose-ci-7284b788…`), which recorded mama's downstream
checkout `sprucegoose-ci` rather than this authoring repository.

## Finding 1 — where the repository actually lives (informational, corrects a prior claim)

The authoring checkout is `/home/admin-papa/governance/sprucegoose` on **papa**. Everything
under `worktrees/` on mama is downstream of it.

An earlier answer in this session named mama's `/home/admin-papa/worktrees/sprucegoose-ci`
as "the" repository. That was wrong in the way that matters: `sprucegoose-ci` sits at
`7284b788`, which is exactly `forgejo/main`, so it is a published-state checkout, while
papa carries the work that has not been published yet. Mama is prod and is never authored
on; asking "where is the repo" on mama finds copies, not the source.

## Finding 2 — HEAD exists on no remote (**material**)

`748e2d13` is ahead 1 of its upstream `forgejo/ops-claude-hooks-and-dist-dropin`, and
`git branch -r --contains 748e2d13` returns **zero** refs. It is on neither Forgejo nor
GitHub. The commit exists on one disk, on one host.

This matters beyond ordinary unpushed work, because the prior audit-handoff bundle
`20260907T193535Z-sprucegoose-748e2d13b8e4-ab3ad72b` records `748e2d13` as its
`source.commit`. A handoff is supposed to let a reader fetch the state it describes.
Anyone acting on that bundle cannot: the commit is unfetchable from either remote, and
the manifest also carries `dirty: true`, so the tree described is not fully captured by
the commit either.

The three commits beneath it (`b5f8408f`, `4e1603d1`, `6b6aa6b5`) *are* on Forgejo via
that upstream branch. Only the tip is missing. Publishing one commit closes the gap.

## Finding 3 — a registered worktree lives in `/tmp` (**minor, time-bounded**)

`.git/worktrees/wt` points at `/tmp/depgate/clean/wt/.git`, a detached checkout at
`5258e4f8`. `/tmp/depgate` dates from 2026-08-31. It survives only until tmp cleanup or
reboot, after which the registration dangles and `git worktree prune` removes it. Nothing
appears to depend on it; it should be pruned deliberately rather than lost silently.

## Finding 4 — worktree registrations here are sound (contrast with mama)

Every linked worktree on papa has its own registration, one-to-one, each `gitdir` file
resolving back to the directory that points at it:

| worktree | branch | HEAD |
|---|---|---|
| `sprucegoose-evidence-link.psZrlc` | `feat/evidence-linker-role` | `a0d35076` |
| `sprucegoose-worktrees/sg-changeA` | `feat/authority-evidence-snapshot` | `7284b788` |
| `sprucegoose-worktrees/sg-oci-blueprint` | `feat/oci-agent-eval-blueprint` | `7284b788` |
| `/tmp/depgate/clean/wt` | detached | `5258e4f8` (see Finding 3) |

`sprucegoose-work` is **not** a repository — it holds `artifacts/`, `backups/`,
`releases/` and a `PRUNED.sha256`. The name invites the mistake; worth knowing before
someone runs a git command in it.

## Finding 5 — mama's `ash-operations` copies share one git registration (**material, still open**)

Carried forward from the first half of this session, because it concerns the same
repository and remains unresolved.

On mama, `worktrees/sprucegoose-ash-operations-v2`, `-v3` and `-v4` are three distinct
working trees sharing a **single** git registration
(`…/sprucegoose-ci/.git/worktrees/sprucegoose-ash-operations-v2`, one HEAD, one index).
`git worktree list` reports only v2. A commit in any of them moves the branch under all
three; `git status` in v3 or v4 diffs that tree against an index describing a different
tree.

The trees hold genuinely different work — 287 / 293 / 301 tracked files under
`lib/ config/ test/ priv/`, nested v2 ⊂ v3 ⊂ v4 by filename, with content also diverging
in 21 files shared by v3 and v4 and 16 shared by v2 and v4. Two renames straddle the
boundary (`executor_startup_guard.ex` → `process_startup_guard.ex`,
`database_role_guard.ex` → `authority_database_role_guard.ex`). **None of it is
committed**, and the branch is level with `main`.

Recommended order: copy all three directories at the filesystem level first; do not run
`git worktree prune`, `git stash` or `git checkout` in any of them until someone decides
which tree wins.

Queued as SpruceGoose inbox capture `inbox-01129be36f8845fa33d26485e3ace896` (pending).

## Recommendations

1. Push `748e2d13` to `forgejo/ops-claude-hooks-and-dist-dropin` so the prior handoff's
   cited commit becomes fetchable. Until then treat that bundle as unverifiable.
2. Resolve mama's v2/v3/v4 collision (Finding 5) before any further work touches those
   directories — uncommitted work is at risk.
3. Prune `/tmp/depgate/clean/wt` deliberately.
4. Commit or discard the 7 dirty paths on `rebase/ops-claude-hooks`, which include the
   prior audit report `docs/audits/2026-09-07-runtime-austerity-reference-links.md`,
   currently untracked.

## Verification performed

Read-only, on both hosts. `git rev-parse`, `git status --porcelain`, `git worktree list`,
`git branch -r --contains`, `git rev-list --count`, `git log`, live `git ls-remote`
against both remotes, `cat` of `.git` and `gitdir` files, `stat`, `sha256sum` over
tracked files, and `comm`/`join` set comparisons.

## Changes made

None. No file in any repository was created, modified or deleted; no branch, index or
HEAD was touched; nothing was pushed; no command was run against the SpruceGoose service
or database.

## Caveat on status

A handoff, not a clearance. It records what was inspected on 2026-09-07 and nothing more.
It does not imply the repository is otherwise healthy, and it neither approves nor
deploys anything.
