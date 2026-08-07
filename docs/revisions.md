# Revisions

Status: **implemented.** A governed way to change what an entity *says*, as a
TOML sparse patch that applies only after an explicit sign-off.

## The gap this closes

The CLI has only ever offered `add`, `rename` and `remove`. Changing a roadmap's
substance, correcting a workflow's DAG, or restating a task's Definition of Done
had no governed path, so it happened out of band — the ungoverned-write problem
`vault-write-authorization.py` exists to make fail loudly on the vault side.

Two revise-shaped Ash actions already existed and were unreachable from the CLI
(`Task.revise`, `Workflow.replace_definition`). `Roadmap` had no revise action at
all. There was no approval concept anywhere.

## Shape

A revision is **proposed** once and **approved** separately. The proposal stores
the TOML body itself, so approval binds to *the bytes that were reviewed*: a
source file edited or deleted between the two steps changes nothing about what
applies.

```sh
sprucegoose revise propose --file /abs/path/rev.toml --as openclaw
sprucegoose revise show rev-20260806T034226Z-9f3c1a04 --as lars
sprucegoose revise approve rev-20260806T034226Z-9f3c1a04 \
    --task tsk-20260806T034000Z-1a2b3c4d \
    --digest 9f3c… --as lars
```

`--digest` is the point. The approver must quote back the SHA-256 that `show`
printed, so a revision cannot be approved without having been looked at.

## Document format

A **sparse patch** plus the `lock_version` you read. Only the fields being
changed appear; anything unmentioned is untouched, so a stale draft can never
silently revert a field it does not know about.

```toml
target = "roadmap:openclaw-system/driftless-ops"
expect_lock_version = 2
reason = "H2 rescope after the ash2 migration"

[change]
name = "Driftless Ops (2026-H2)"
```

Workflow DAGs use TOML's array-of-tables, and are validated at **propose** time
through the existing `Definition` DAG validation, so a cycle never reaches
sign-off:

```toml
target = "workflow:openclaw-system/driftless-ops/driftless-ops-v1"
expect_lock_version = 1
reason = "insert the recovery-rehearsal phase before canary-rollout"

[change.definition]
schema_version = 1

[[change.definition.tasks]]
id = "recovery-rehearsal"
kind = "oban"
depends_on = ["degraded-reconciliation"]
```

### Targets and revisable fields

| `target` | reference form | revisable |
|---|---|---|
| `roadmap:` | `PROJECT/ROADMAP` | `name` |
| `workflow:` | `PROJECT/ROADMAP/WORKFLOW_ID` | `name`, `definition` |
| `task:` | `tsk-…` | `title`, `description`, `definition_of_done`, `runner`, `input` |
| `board:` | UUID | `name` |
| `column:` | UUID | `name`, `position` |
| `filter:` | UUID | `name`, `criteria` |

**Identity fields are never revisable.** `roadmap.key`, `workflow.workflow_id`,
`task.task_id`, `board.key` and `column.key` are how the vault's Markdown
references these entities (`roadmap:agent-work-authority-routing`), so changing
one silently breaks every link pointing at it. Renaming an identity is a
migration, not a revision, and the CLI says so by name rather than as a generic
"unsupported key".

Task board metadata — `priority`, `labels`, `assignees`, `due_at` — stays on
`task metadata ID JSON`. It is scheduling data, not the governed statement of the
work, and gating it would add friction without adding assurance.

For a roadmap, `name` is the only revisable field, because the row is just
`key` + `name`. What is new for roadmaps is the **gate**, not new fields; the
substance still lives in `65-roadmaps/*.md`.

## Gates on approve

All must hold, and failing any leaves the revision `pending` with nothing
partially applied:

1. The revision is `pending`.
2. `--digest` matches the stored `source_digest` exactly.
3. The approver holds `approver` over the revision's project scope, fixed at
   proposal time.
4. The approver is not the proposer — see below.
5. `--task` names a real task in state `in_progress` whose Systemwide SOP
   acknowledgment verifies. This defers to `SpruceGoose.SopGate.verify/1` rather
   than restating the rule `vault-write-authorization.py` already encodes;
   keeping one rule in two places is how they drift.
6. The target's current `lock_version` still equals `expect_lock_version`. If it
   moved since the proposal, the recorded diff no longer describes reality, so
   the answer is "re-propose", not "apply anyway".

The entity update and the sign-off record commit in one transaction. An applied
change with no record of who approved it is exactly the ungoverned write this
verb exists to prevent.

### Self-approval

Refused by default. `--self` is the exception, and it is available **only to
actors of kind `:human`**; when used it is recorded on the revision as
`self_approved`.

An agent proposing and approving in one breath is not a review, it is a loop
closing on itself. A single human operator signing off on their own work is a
real situation on this fleet, so it is permitted — but explicitly, and on the
record.

## Storage

`SpruceGoose.Workflows.Revision` keeps `source_body` byte-exact
(`constraints: [trim?: false]`). Ash trims `:string` by default, which drops the
trailing newline every editor writes — and then the stored body no longer hashes
to `source_digest`, so what was signed off could not be reproduced from the
record. `test/revise_test.exs` pins that invariant directly.

`project_key` is denormalized from the target at propose time. A revision's scope
is fixed when it is proposed, not re-derived at approve time, and the flat column
is what lets a project-scoped reader's `revise list` filter rather than walk to a
target that may since have been removed.

## Passing the file

The `sprucegoose` client is a thin Unix-socket client; the **service** reads the
file, not your shell. `--file` must therefore be **absolute** — a relative path
would resolve against the service's working directory — and a relative one is
refused with that explanation rather than silently resolving somewhere else.

Reads are capped at 64 KiB, matching the socket plug's body ceiling. A revision
that does not fit is a rewrite, not a revision.

## CLI

```
revise propose  --file ABSOLUTE_PATH
revise list     [--state pending|applied|withdrawn|all] [--target REF]
revise show     REVISION
revise approve  REVISION --task TASK_ID --digest SHA256 [--self]
revise withdraw REVISION REASON
```

The acting party comes from the global `--as`, never a separate `--by`: two names
for the same party is how they end up disagreeing.

## Related

- `docs/authorization.md` — the `proposer` / `approver` roles that gate this.
