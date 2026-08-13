# Governed release provenance

SpruceGoose release artifacts use two closed, canonical JSON objects. The embedded `spruce-goose-release-provenance-v1` member records exact source commit/tree/dirty state, explicit UTC build time, builder, governed task and transaction, actual Elixir/Erlang/Mix versions, and every tracked migration in strict path order with SHA-256 plus a digest of the ordered set. The external `spruce-goose-release-receipt-v1` avoids self-reference by binding the final archive basename and SHA-256 to the embedded provenance SHA-256. Missing, extra, duplicate, unordered, malformed, or noncanonical representations fail closed.

`inspect-governed-release ARCHIVE` reads gzip/tar bytes without extracting, writing candidate files, or starting the release/application/Repo. Exactly one `releases/<dynamic-version>/governed-provenance.json` member is required; no application version is hardcoded. `validate-governed-release` validates canonical receipt, archive name/digest, unique embedded member and digest/schema, dirty policy, expected commit/tree, then the exact canonical destination migration inventory. Destination-looking paths are never accepted as mutation targets.

Destination inventory is required by default. `--artifact-only` is an explicit weaker evidence mode and prints `mode=artifact-only`; it proves artifact self-consistency only, not destination readiness. `--allow-dirty` accepts only explicitly classified `non-transferable-dirty-evidence`; it never makes an artifact clean or transferable.

`build-governed-release` rejects dirty source before output creation or Mix invocation. Dirty exercise requires both `SPRUCE_GOOSE_ALLOW_DIRTY_EVIDENCE=1` and a pre-existing `SPRUCE_GOOSE_DIRTY_EVIDENCE` file. Builder, governed task/transaction, UTC time, output directory, and `SOURCE_DATE_EPOCH` are explicit inputs. Mix project identity is read only after warnings-as-errors compilation using `mix run --no-start --no-compile`. Archive order, timestamps, ownership, gzip timestamp/name, and modes are normalized.

## Evidence classes

* **Source/static PASS:** formatter, standalone compilation, unit/script regressions on exact bytes.
* **Boot-free behavioral PASS:** canonical codecs, in-memory archive inspection, CLI/parser, receipt/validator, and no-write accounting.
* **Dirty build exercise:** always non-transferable evidence, even if repeated bytes match.
* **Transferable clean release:** requires a clean committed candidate built twice with identical declared inputs, byte-identical archives and receipts, and successful full validation against destination inventory.
* **UNEXECUTED:** dependency/setup prevented execution; it is neither PASS nor implementation FAIL.

Production integration, destination inventory capture, application/Repo/runtime boot, DB migration, service activation, transfer, staging, and authority mutation are **UNEXECUTED and prohibited for this implementation task**. Implementation completion does not claim a transferable release. Any workspace write not explicitly intended—including `erl_crash.dump`—invalidates read-only evidence; before/after inventories must reject it.
