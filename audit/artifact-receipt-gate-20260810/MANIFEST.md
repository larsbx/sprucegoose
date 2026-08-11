# Artifact-receipt gate audit manifest

Status: prepared for independent read-only audit

## Authority and scope

- Preparation task: `tsk-20260810T124313Z-454ffe33`
- Implementation task: `tsk-20260810T121734Z-08f8afe9`
- Development dogfood task: `tsk-20260810T122739Z-b1701e0e`
- Repository: `/home/admin-papa/sprucegoose`
- Branch at preparation: `remediation/sprucegoose-audit-20260810`
- Base commit: `cb6dcb02dd44a1fc4c5c3d84ace57c0d2d073c19`
- Reviewed commit: `2d77e5994fc470e716ae5f8156b90953a5a1e590`
- Reviewed tree: `cedba21a1a4100f4f25c8dd1722c55d49d0a92ad`
- Production promotion: prohibited during this audit
- Remediation: prohibited during this audit
- Publication and credential changes: prohibited during this audit

The Papa working tree was clean before this audit metadata was added. Papa's
local SpruceGoose service is inactive. The authoritative CLI path is restored
to the active `sprucegoose-remote-client.service` SSH bridge to Mama. The
reviewed commit has not been promoted to Mama.

## Changed-file custody

| Path | Bytes | SHA-256 |
|---|---:|---|
| `README.md` | 9474 | `2b5aeb5c4ba042426eef7f4d385038595e8fc0cb22857c4733353b1e8b2982ea` |
| `lib/spruce_goose/cli/command.ex` | 21500 | `8a628e006a7e637beb45fb82de1f13618a1ad7d37a7bcbf5f9dba5f6a1e978d4` |
| `lib/spruce_goose/cli/executor.ex` | 54080 | `cd959f1a4f250494512ecc6108bb1a947e49336337ccd02fec59785179755460` |
| `lib/spruce_goose/workflows/task.ex` | 19810 | `97915656bb1123f0f703ffb6a38e916644f72a67322416aebe0404c708d07ac1` |
| `priv/repo/migrations/20260810121915_add_artifact_receipts.exs` | 590 | `c15992317b225faf2013fdd78ad8356930edb43f4444ce8a7d3802d843676f67` |
| `priv/resource_snapshots/repo/workflow_tasks/20260810121916.json` | 11231 | `ce16ecbc705445aa8c0252e53ab72858f4c2f71c9d0562b4fce4b72ee8925d6b` |
| `test/cli_database_test.exs` | 45886 | `f186321432e29a6114ad00f0ad3cebe512afbaf6351c24d0f741ac8600f489ea` |
| `test/cli_test.exs` | 19029 | `b12f22a2715bf7a7dd48148420c01880a6e816fe5b4ab38ee5caf924b5e52daf` |

Total changed-file bytes: 181600.

## Recorded verification

- `mix format --check-formatted`: passed.
- `mix compile --warnings-as-errors`: passed.
- `mix test`: 231 tests, 0 failures.
- Development migration applied to `spruce_goose_dev` and
  `spruce_goose_test`.
- Focused artifact gate tests: 2 tests, 0 failures.
- Repository secret hook: `clean: no credential material detected`.
- Development compiled-CLI proof refused `ready` before receipt, accepted a
  receipt, entered `ready`, started, completed its TODO, linked evidence, and
  completed task `tsk-20260810T122739Z-b1701e0e`.

Ada MUST reproduce relevant checks independently and MUST treat the recorded
results as claims, not as audit evidence by themselves.

## Known high-risk questions

The audit must determine whether the implementation actually enforces the
stated contract, including these suspected seams:

1. Does a nonblank `storage_locator` prove immutability, or can an arbitrary
   mutable path pass?
2. Does a caller-supplied verifier name and timestamp prove an independent
   retrieval, or is the receipt self-attested?
3. Is receipt append plus validation atomic under concurrency, or can stale
   writers lose or replace a receipt?
4. Can direct Ash actions, `move`, revision actions, imports, or database writes
   bypass readiness or receipt immutability?
5. Are duplicate requirements, duplicate receipts, malformed JSON, oversized
   maps, extra fields, timestamps, zero-byte artifacts, and Unicode names
   handled fail-closed?
6. Does the migration preserve all historical rows without inventing evidence,
   and does rollback avoid silent loss?
7. Are authorization roles narrow enough for receipt creation and evidence
   linking?
8. Does the authoritative Mama deployment remain unchanged during the audit?

## Runtime pin

- Elixir: 1.19.5
- Erlang/OTP: 28 / ERTS 16.2
- Mix: 1.19.5
