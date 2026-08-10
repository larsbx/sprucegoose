# SpruceGoose pre-remediation baseline

- Task: `tsk-20260807T162220Z-68f99dee`
- Captured: `2026-08-10T01:48:29Z`
- Specification: `SPEC-SPRUCEGOOSE-REMEDIATION-2026-08-07`
- Specification SHA-256: `0f44ae59b737443d114a05faff902b6bc259fc4bd142b757aa813373c854b8ce`
- Audited base: `3a85527f917dc665944861dce3d4ba1144235b00`
- Approved descendant and remediation base: `71057a6b375779bf9bba1e2375ddc1da22fea41d`
- Branch: `remediation/sprucegoose-audit-20260810`
- Ancestry check: `git merge-base --is-ancestor 3a85527f917dc665944861dce3d4ba1144235b00 HEAD` exited `0`.
- Pre-branch tree check: `git status --porcelain=v1` produced no output.
- Host: `Linux 6.8.0-136-generic x86_64 GNU/Linux`

## Integrity and toolchain

- `git fsck --full` exited `0`. It reported 17 dangling blobs and one dangling commit; it reported no corrupt or missing object.
- Erlang/OTP: `28` (`erts-16.2`)
- Elixir: `1.19.5`, compiled with Erlang/OTP 28
- Mix: `1.19.5`, compiled with Erlang/OTP 28
- `mix.lock` SHA-256: `6320a4a82b5a4150541209977e38f651f1f81f8e8fd47bdbce1a30c3eb73db56`
- Migration-tree SHA-256: `5bf6b770efb709ea39e9ba1801e13aafdd5c909344e4dcbf9df2d9e30d36ef69`

The migration-tree digest was computed by sorting the NUL-delimited paths beneath `priv/repo/migrations`, hashing each file, and hashing that manifest.

## Fresh-clone full suite

A new local clone was created with `git clone --local --no-hardlinks` into a fresh directory under `/tmp`. The clone's `git status --porcelain=v1` produced no output before dependency resolution. It used its own dependency and build trees.

Commands:

```sh
mix deps.get
MIX_ENV=test mix test
```

Result:

```text
Finished in 14.5 seconds (6.5s async, 7.9s sync)
214 tests, 0 failures
BASELINE_TEST_EXIT=0
```

Dependency resolution preserved the locked versions and reported current advisories for Ash 3.29.3, Postgrex 0.22.3, and ymlr 5.1.5. This baseline records those findings; it does not remediate them. Dependency remediation remains governed by its dedicated workstream.

## Boundary

This receipt captures a clean-checkout baseline on the current host. It does not claim a separate production-like host, production deployment, migration, release promotion, or recovery rehearsal.
