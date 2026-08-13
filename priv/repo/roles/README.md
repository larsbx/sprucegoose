# Database role declarations

Files in this directory are **declarations, not migrations**. Nothing here is
applied automatically, and nothing here has been applied to any database.

```text
STATUS:          NOT APPLIED
APPLIED TO:      no database, local or remote
GOVERNING TASK:  tsk-20260813T141153Z-336632d6
```

## Why these are not migrations

Role and grant changes are privileged operations against a live cluster. If
they lived in `priv/repo/migrations/` they would execute on every
`mix ecto.migrate`, including against the production authority, as a side
effect of an unrelated deploy. Keeping them here makes application an explicit,
reviewable act.

`test/ci_scaffold_test.exs` asserts that no migration references
`sprucegoose_readonly`, so the separation is enforced rather than assumed.

## Contents

| File | Purpose | Applied |
|---|---|---|
| `sprucegoose_readonly.sql` | scoped read-only role for the migration-parity preflight | no |

## Applying one

Out of scope for this task. Application requires its own governed task, an
explicit target, a reviewed grant set, and evidence — the same bar as any
other production mutation.
