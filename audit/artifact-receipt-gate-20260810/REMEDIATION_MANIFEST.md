# Artifact-receipt custody remediation manifest

Status: prepared for independent read-only re-audit

## Authority and scope

- Governing remediation task: `tsk-20260810T132212Z-baf78a04`
- Controlling Ada report SHA-256: `9a96fe25f8720e28f208bab27b4db0f46060f213f5d002964bbab6aaeb088ed5`
- Audited implementation commit: `2d77e5994fc470e716ae5f8156b90953a5a1e590`
- Audit report commit: `6f8e71b4a2f7676aad5325e77ad7a42dc0244160`
- Remediation commit: `cd4496dc5f7704ec4d746dedea98b8049ea8264f`
- Remediation tree: `d057bc5ffc5c549362a5e16f02bf5f01a30078a0`
- Development custody proof: `tsk-20260810T133810Z-c3290221`
- Production promotion: prohibited during re-audit
- Mama authority mutation: prohibited during re-audit

## Finding disposition

1. Self-attestation is replaced by a trusted retrieval path. The executor accepts
   a source path and source identity only; it reads a stable, regular, nonempty,
   bounded file, derives the SHA-256 and byte size, writes immutable CAS content,
   and derives the locator, verifier identity, and verification timestamp.
2. Receipt creation requires `artifact_verifier`. A verifier who also holds the
   task-scoped operator role is refused, separating custody attestation from the
   readiness operator.
3. PostgreSQL enforces receipt presence and canonical receipt semantics whenever
   state enters `ready`, including direct SQL and legacy writers.
4. Receipts have an exact seven-key schema, bounded fields, positive size,
   digest-bound `cas:sha256:` locator, and non-future verification time.
5. Rollback refuses to drop either custody column while requirements or receipts
   exist. Empty historical rows remain compatible without fabricated evidence.

## Changed-file custody

The following files differ between audit report commit `6f8e71b4` and remediation
commit `cd4496dc`:

| Path | Bytes | SHA-256 |
|---|---:|---|
| `README.md` | 9319 | `bbe1fa0cb37499246129f44c2d36512dd421dab20d46c04697a054041a35b6be` |
| `config/config.exs` | 2802 | `3b6099bd55d8ad2c3450415c3ed46c24a166935e86e662dafb9bf4a0b02ff517` |
| `config/runtime.exs` | 4378 | `4902e70cd42fac159d61dd9a9c32ff07d8ec5a3aae667644d71fe15e1d44f8a9` |
| `lib/spruce_goose/actors/role.ex` | 476 | `9fe01131f62c71b33f814340d991ad5513de1b34b5ba4311027131bbf8fd8e2b` |
| `lib/spruce_goose/artifacts/store.ex` | 4441 | `16b2fb28dc0c0cd8bcb6399ed81b59fd297f3e290d195dc82aeca4d6bdeb9276` |
| `lib/spruce_goose/checks/has_role.ex` | 1489 | `8be2f74c82708de9555e10179be815185e0cfefff1883fcdd750eb0d3b900e00` |
| `lib/spruce_goose/cli/command.ex` | 21588 | `9d109673a4243e3d65e42fdcb8c25a538dbacc1dc614a83c25d55b3631f46412` |
| `lib/spruce_goose/cli/executor.ex` | 54620 | `eea209a556cc7ee2ed783fd985b7d4543dd4d6849bf1587871ccc58e7c6ececd` |
| `lib/spruce_goose/workflows/task.ex` | 20062 | `98de331227d2225799959c9d0f7b26b24edc5aadf449abd5e5d62f6187ec9fb8` |
| `priv/repo/migrations/20260810121915_add_artifact_receipts.exs` | 3027 | `0bb59a00c286d0f335d96668a82a74ed83ea12d7883a714c47ab0003df5df9fa` |
| `priv/repo/migrations/20260810133000_harden_artifact_receipt_custody.exs` | 2810 | `1582b7c5ccb518aa4868c5e61cf7d20cd90f251fe1640582d2281e6f4ca800a1` |
| `test/cli_database_test.exs` | 47488 | `618d09fe6441ce2dca6f309842ef6dda2997f2b7dea3276298bbe4ef4b471a6d` |
| `test/cli_test.exs` | 19131 | `078a31ffbf9252f9cb07d1144d871fef13e980f6e71fdb23beb102599dff5313` |
| `test/test_helper.exs` | 1843 | `f56cfebd12705c6756106218182effb0be4d4800444b402e12448eb8036c0c06` |

## Recorded verification claims

- Focused custody tests: 2 tests, 0 failures.
- Full suite: 231 tests, 0 failures.
- Formatting, warnings-as-errors compilation, and Ash migration drift checks passed.
- Development migration applied successfully.
- Rollback with custody evidence positively refused instead of deleting evidence.
- Compiled CLI refused readiness before receipt, derived and stored a verified
  receipt through a distinct verifier, then admitted and completed the task.
- Papa local SpruceGoose service remained inactive; the Mama bridge remained
  active; Mama was not mutated.

These are implementation claims. The re-auditor must reproduce them independently.
