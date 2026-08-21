# SpruceGoose mama authority migration

Status: complete on 2026-08-02 UTC

Governing task: `tsk-20260802T135008Z-e3a6671f`

## Cutover record

- Evergreen's application service was stopped before the final dump and is
  disabled. Its PostgreSQL service and unchanged database remain available as
  rollback state; there is no local application writer.
- The final frozen dump is
  `/home/admin-papa/migration-snapshots/sg-final-precutover-20260802T143504Z.dump`
  on both hosts, mode `0400`, with its adjacent SHA-256 and core-count files.
- The dump was checksum-verified after transport and restored over only mama's
  staging `spruce_goose_dev` database.
- Mama's `sprucegoose-postgresql.service` and `sprucegoose.service` are enabled
  and active. Both were restarted after cutover and returned active.
- Evergreen's `sprucegoose-remote-client.service` is enabled and active. It
  forwards the existing mode-`0700` Unix-socket path over authenticated SSH;
  no SpruceGoose TCP listener was added.

## Parity and dogfood

The final frozen evergreen snapshot and the restored mama database matched:

| Resource | Rows |
| --- | ---: |
| projects | 13 |
| roadmaps | 23 |
| workflows | 32 |
| workflow_tasks | 424 |
| task_todos | 63 |

After parity, the evergreen CLI created and completed a new mama-hosted chain:

- project: `sg-mama-cutover-20260802`
- roadmap: `cutover-verification`
- workflow: `cutover-verification-v1`
- task: `tsk-20260802T143717Z-ce688275`
- TODO: `todo-b6926fbdf4c9a36bc4f54279682438e2`
- lifecycle: `propose -> queue -> ready -> start -> completed`

The task stored the current Systemwide SOP digest, its TODO was completed, and
the completed task remained readable after restarting mama PostgreSQL, the mama
application service, and the evergreen bridge.

## Rollback proof

A fresh post-cutover mama dump was checksum-verified and restored into the
isolated evergreen database `spruce_goose_rollback_verify_20260802`. Restored
counts matched the live mama source at `14 / 24 / 33 / 425 / 64`; the scratch
database was then dropped. The retained proof dump is
`/home/admin-papa/migration-snapshots/sg-postcutover-rollback-verify-20260802T1438Z.dump`,
mode `0400`, on both hosts.

Operational rollback must first stop mama writes, take and verify a fresh dump,
restore it to evergreen, compare counts, and only then switch services. The
pre-cutover dump is a last-known-good recovery point and must not be used as an
automatic fallback after new mama writes.
