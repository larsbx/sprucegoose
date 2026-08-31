# Erratum: the admission bootstrap manifest rested on a false premise

Date: 2026-08-31

`.sprucegoose/admission-bootstrap.yaml` was authored, reviewed, approved, and
merged on the claim that task admission was closed fleet-wide. That claim was
false. The manifest was **never registered and never applied**, so no authority
state was derived from it.

This erratum is additive. No Git history is rewritten and no commit is reverted.
The false commits remain reachable so the record stays auditable.

## Affected commits

| Role | Commit |
|---|---|
| False source commit | `22c3d9b8fbfa21fb4aae8b71e0f39fee9fc0600d` |
| Merge commit | `5258e4f8465da59894b998359fff28f74ff9520c` |
| Corrected successor | the commit that introduced this file |

A commit cannot contain its own hash, so the successor is identified by the
commit that adds `.sprucegoose/operational-assurance.yaml` alongside this
erratum. `git log --diff-filter=A -- docs/errata/2026-08-31-admission-bootstrap-false-premise.md`
resolves it exactly.

## The false claim

The commit message of `22c3d9b8` states:

> Task admission has been closed since a7cf038f retired `task add`:
> workflow_blueprint_revisions is empty, so `task instantiate` has no
> revision to bind to and no task can be created.

Every clause after the first is wrong. `workflow_blueprint_revisions` was not
empty, `task instantiate` had a revision to bind to, and tasks could be and had
been created.

Two task definitions encoded that false premise in their identifiers and
definitions of done, and are dropped rather than reworded:

- `admission-gate-diagnosis`
- `admission-blueprint-bootstrap`

The roadmap and workflow identifiers `task-admission-bootstrap` /
`admission-bootstrap-v1` are likewise retired in favour of
`operational-assurance-backlog` / `operational-assurance-v1`.

## Root cause

Authority state was read from the wrong database.

`spruce_goose_dev` on papa is a stale local development instance. The
SpruceGoose authority store is the database reached through the authenticated
Unix-socket service on mama (`~/.config/sprucegoose/authority-host` names
`mama`). Papa's `./sprucegoose` executable is a thin socket client, not a direct
database client, so the CLI and a local `psql` session on the same host answer
from different stores.

A `psql` query against papa's local instance returned zero blueprint revisions
and 437 tasks. That result was treated as fleet-wide fact and carried forward
into the manifest, its commit message, and the review request.

The discrepancy was observable before the manifest was written: the CLI reported
752 tasks on the same host where `psql` reported 437. The divergence was noticed
and papa was correctly identified as non-authoritative, but the blueprint
revision count was never re-queried against mama.

## Authority snapshot

Taken on mama, 2026-08-31T02:42:33Z, against `spruce_goose_dev` through the
authority host's PostgreSQL instance:

| Measure | Authority (mama) | Stale local (papa) |
|---|---|---|
| `workflow_blueprint_revisions` | 36 | 0 |
| `workflow_tasks` | 752 | 437 |
| Tasks bound to a blueprint revision | 69 | 0 |
| `openclaw-system` revisions | 31 | 0 |

The most recent `openclaw-system` revision at the time of the snapshot was
`bpr-ca3df21696fadbb05a049b9ef81da29b4f15fe416275bf726bbf543ab43bbc70`, from
`root/sprucegoose` `.sprucegoose/project.yaml` at commit `b2da68529c39`,
recorded 2026-08-29.

Counts are a point-in-time snapshot, not a durable property of the system. They
are recorded here, in a dated document, rather than in the manifest.

## Review accountability

The review of `22c3d9b8` verified manifest syntax, typed definitions, expected
application behaviour, exact source bytes, test results, merge-tree equality,
and separation of duties. All of those passed and remain valid findings.

None of them tested whether the manifest's stated purpose was true. A correct
implementation review does not establish a correct operational premise. The
premise should have been re-established against the authority database before
approval, and the papa/mama discrepancy was available evidence that it needed to
be.

## Disposition

- The false manifest is ineligible as a blueprint registration source.
- It was never registered, applied, or instantiated from.
- No production or hierarchy mutation occurred.
- `.sprucegoose/operational-assurance.yaml` supersedes it with four retained
  definitions and neutral identifiers.
- Before the successor is registered, the existing `openclaw-system` revisions
  must be inventoried to confirm the retained definitions are not already
  adequately represented.
