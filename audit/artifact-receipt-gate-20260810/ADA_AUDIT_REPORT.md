# Independent Ada audit — artifact-receipt readiness gate

Date: 2026-08-10 UTC  
Auditor role: independent, read-only, adversarial  
Controlling verdict: **NOT READY**

This advisory report does not authorize production promotion.

## Pinned identities and custody

- Repository: `/home/admin-papa/sprucegoose`
- Base commit: `cb6dcb02dd44a1fc4c5c3d84ace57c0d2d073c19`
- Reviewed commit: `2d77e5994fc470e716ae5f8156b90953a5a1e590`
- Reviewed tree: `cedba21a1a4100f4f25c8dd1722c55d49d0a92ad`
- Audit-bundle commit: `b1b0b9c89aa8ef269b3c7c80019a397d99bcb628`
- `git rev-parse COMMIT^{tree}` matched the declared tree; `git merge-base BASE COMMIT` matched BASE. The eight changed paths matched `git diff --name-status` exactly.
- Every manifest byte count and SHA-256 matched Git-archived source; total was exactly 181600 bytes.

## Findings (severity order)

### Critical — receipt semantics do not prove immutable custody or independent retrieval

`lib/spruce_goose/workflows/task.ex:413-426` validates only field types, a lowercase SHA-256 shape, nonblank locator/source/verifier strings, and parseable timestamp. It never retrieves an artifact, hashes retrieved bytes, binds locator to digest, establishes locator immutability, authenticates source/verifier identity, requires verifier independence, bounds timestamp to the present, or rejects zero bytes/extra fields. The same operator is authorized to record the receipt and transition the task (`task.ex:26-34`).

Positive adversarial proof independently accepted a receipt with `storage_locator=/tmp/mutable/latest`, caller-asserted source/verifier, year-2999 timestamp, zero size, and an extra field; the task then entered `ready`. A blank locator was rejected, proving the harness observed both acceptance and refusal. Therefore the original custody gap remains open.

### High — database and legacy refresh paths bypass the readiness invariant

The readiness check exists only in Ash `:transition` and `:move` action validations (`task.ex:196-223`, `226-275`, `372-388`). There is no PostgreSQL constraint or trigger. A positive-control direct SQL update independently moved an artifact-dependent queued task to `ready` with `artifact_receipts=[]` after the Ash action refused the same transition. The privileged legacy refresh also writes `workflow_tasks.state` directly (`lib/spruce_goose/ledger.ex:620-666`), bypassing Ash validations, although migrated legacy rows default to no artifact requirements. Database access remains an explicitly trusted boundary, not an enforced custody boundary.

### High — rollback silently destroys custody declarations and evidence

Migration `priv/repo/migrations/20260810121915_add_artifact_receipts.exs:17-21` drops both columns on rollback. Any recorded requirements and receipts are irreversibly lost without an export/refusal gate. This is not a production-safe rollback after receipts exist.

### Medium — schema permits weak/unbounded receipt payloads

Receipt maps permit arbitrary extra keys and have no per-field or aggregate map bounds (`task.ex:413-431`). The socket limits each argument to 4096 bytes and body to 65536 bytes (`lib/spruce_goose/cli/socket_plug.ex:7-9,25-44`), but direct Ash callers are not equivalently bounded. Malformed JSON and non-object JSON fail closed (`executor.ex:1514-1518`); duplicate requirements and duplicate receipt names fail closed (`task.ex:394-406`); Unicode names are accepted subject only to nonblank and 128-byte bounds. Zero-byte artifacts are explicitly accepted (`task.ex:416`).

## Contract coverage and bypass analysis

- `transition` to ready: guarded, but only for presence of syntactically valid maps.
- `move` into a ready column: uses the same readiness guard.
- `record_artifact_receipt`: prohibited after ready and uses `lock_version` optimistic locking (`task.ex:159-170`). A stale-writer positive control showed the first valid append accepted and the second stale update rejected, so ordinary concurrent writers do not silently replace the first receipt. The CLI read/append/update is not a single database statement, but optimistic locking converts contention to an error.
- `revise`: cannot accept requirements, receipts, or state (`task.ex:153-157`).
- creation: accepts requirements but not receipts or state; starts inbox.
- direct Ash actions: named transition/move routes enforce the presence check. Bare system-authority Ash calls may bypass authorization by domain design, but cannot bypass named action validation.
- imports/direct database writes: direct state SQL bypasses the gate; demonstrated.
- malformed JSON: rejected. Duplicate requirement/receipt: rejected. Extra fields, future timestamps, zero bytes: accepted. Oversized socket argument: rejected at 4096 bytes, while direct callers lack that boundary.

Controlling contract answer: **No**. An artifact-dependent task can become ready with a wholly self-attested receipt that provides no verified immutable locator or independent retrieval evidence; a direct database writer can also bypass receipt presence entirely.

## Migration and historical-row verdict

Upgrade adds non-null arrays with empty defaults, so historical rows remain representable without invented evidence. Old application code can tolerate additive columns, and new code interprets historical rows as having no artifact requirement. Migration drift check was clean. Rollback is destructive and must not be treated as safe once either column contains data. Verdict: forward historical compatibility acceptable; rollback unacceptable without an explicit preservation/refusal plan.

## Authorization verdict

Project/global scope checks are enforced on the Ash CLI path, and receipt creation is operator-scoped. That role is not narrow enough for the claimed independent retrieval contract because the same operator can manufacture verifier/source/timestamp values and drive readiness. No authenticated distinct retriever or approver boundary exists. Verdict: **not sufficient**.

## Authority topology

Before and after checks showed local `sprucegoose.service` inactive, `sprucegoose-remote-client.service` active, repository HEAD still the audit-bundle commit, and the reviewed checkout clean. No authoritative Mama socket, service, database, credentials, deployment, or publication was touched. Tests used a uniquely named disposable local PostgreSQL database on the Papa-local `sprucegoose-postgresql.service` and an archived temporary reviewed tree.

## Independent verification results

- Runtime: Elixir 1.19.5; Erlang/OTP 28 / ERTS 16.2; Mix 1.19.5 — matched manifest.
- `mix format --check-formatted` — pass.
- `mix compile --warnings-as-errors` — pass.
- Fresh disposable database, `MIX_ENV=test ... mix ecto.migrate` — pass through `20260810121915`.
- Fresh disposable database, full `mix test` — 231 tests, 0 failures.
- `mix ash_postgres.generate_migrations --check` — pass/no drift.
- Independent `/tmp` adversarial harness — 3 tests, 0 failures; acceptance and refusal controls described above.
- Secret scan (`kb-secret-scan.py`) of archived reviewed tree — 214 files, clean. Positive control containing a synthetic OpenAI-shaped key was detected and refused with exit 1.
- Manifest identities/digests — all pass.

No live production test, Mama connection, deployment, restart, push, or promotion was attempted, by contract.

## Final verdict

**NOT READY.** Production-promotion admission must remain refused until receipt evidence is generated or verified by a trusted distinct boundary, retrieval and digest/size are actually checked against immutable storage, database/import paths enforce the same invariant, receipt payloads are bounded/canonical, and rollback preserves or explicitly refuses loss of evidence.

Report SHA-256 is computed over the finalized file and supplied with the audit handoff (a digest cannot be embedded in the bytes it hashes without changing that digest).
