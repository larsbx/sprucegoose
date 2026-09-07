# Client reliability and operational audit — 2026-09-07

## Scope and assessment

Source baseline: Papa's `~/sprucegoose` at
`b5f8408f2cfaa1301790ac222e2d1df8cc74856d`; the checkout subsequently moved to
`~/governance/sprucegoose` during fleet directory maintenance. Review covered the thin client,
socket request handling, actor resolution, MCP boundary, CI entry point,
existing client tests, current-state documentation, and selected service and
backup metadata on Mama. This is not a complete security audit, dependency
advisory scan, database reconciliation, restore rehearsal, or authorization
to transfer authority. It supplements the existing kernel conformance audit.

The core has useful explicit boundaries: scoped actors, immutable source
bindings, transactional state, bounded server execution, and release provenance.
The weaker area is the operator path. Small client parsing and transport errors
can defeat its advertised behavior, while historical documentation can look like
current operational evidence. Improve those contracts before adding more
orchestration machinery.

## Findings addressed in this change

| Priority | Finding | Change |
| --- | --- | --- |
| P1 | `--as codex task start ...` skipped client SOP parity preflight because dispatch inspected only the first two raw arguments. This is a client preflight defect, not proof of bypassing the server's SOP or authorization checks. | Client command classification removes the global actor declaration without altering the request sent to the server. |
| P2 | A global actor prefix disabled automatic task pagination. A search value equal to `--limit` also looked like an explicit paging flag. | Recognize the command after actor extraction and consume option values atomically. Explicit paging remains unchanged. |
| P2 | `socket.settimeout` bounded each blocking operation, not the entire round trip. A response arriving a little at a time could prolong the request. | Use a monotonic deadline shared by connect, send, and all receives. Keep the existing response byte cap. |
| P2 | JSON arrays, null, and non-boolean success flags were accepted as service envelopes; later `.get` calls could crash. An HTTP failure could carry `ok: true`, and malformed task pages could look successful. | Validate the HTTP status and JSON object/boolean envelope, reject error statuses claiming success, and reject malformed task batches with JSON errors. |
| P2 | Invalid page-size and timeout environment values produced tracebacks or nonsensical socket/paging behavior. | Validate numbers before connecting. Page size must be an integer from 1 to 100,000; timeout must be positive, finite, and at most 86,400 seconds. Defaults remain 100 rows and 35 seconds. |
| P2 | The format parser treated an option-looking value as another option, hiding a subsequent `--format`. | Consume a value with its owning option; preserve literal search terms. |
| P2 | The current-state document named an August 22 release, but Mama's installed provenance identifies an August 24 release. | Separate the newly observed installed provenance and backup status from historical behavioral measurements. |

## Validation and limits

`scripts/test_cli_client.py` is a standard-library unittest suite. It exercises
the transport with deterministic socket/clock doubles, invokes subprocesses
for invalid configuration, verifies canonical success and refusal envelopes,
checks argument handling, and checks pagination order and response-cap retries.
The baseline client failed the new regression cases. Run without a database,
credentials, or live service:

```sh
python3 -B -m unittest discover -s scripts -p test_cli_client.py
```

Verified results: 12 Python tests passed on both adder-ws and Papa. On Papa,
the client wrapper plus existing SocketPlug and SocketService suites passed
9 ExUnit tests, including real Bandit Unix-socket requests, service absence,
concurrent requests, timeouts, and socket restart cleanup. These focused
tests ran with `mix run --no-start --no-compile`, starting Bandit explicitly
and loading only those test files, so they did not boot the production
application or touch its database. The new ExUnit file passed
`mix format --check-formatted`; the patch passed `git diff --check`.
The full database-backed suite and governed release build were not run.

`test/cli/client_test.exs` also invokes this suite from the existing `mix test`
lane, so the normal governed CI path includes it. The `-B` flag keeps Python
bytecode caches out of the candidate workspace. No new dependencies are added.
Timeouts are per round trip/page; a multi-page listing is not a snapshot and
does not acquire a single end-to-end deadline. Existing aggregate row and byte
bounds continue to apply. A client timeout cannot establish whether a server
mutation committed; mutations are never automatically retried here.

These source changes do not themselves replace the installed thin clients or
activate a new Mama OTP release. Build and promote through the existing release
procedure; do not overwrite Mama's installed client with Papa's host-specific
copy. Existing uncommitted git-hook work is outside this patch.

## Remaining critique and next work

1. **Portability:** `sop_preflight` still names an absolute Papa vault path,
   SSH alias `mama`, and a repair script absent from this checkout. Mama's
   installed client hash differs from Papa's. Define explicit host configuration
   and prove a complete read/start/acknowledgment path on each supported host
   before unifying those clients.
2. **Evidence freshness:** Generate a bounded operational report from installed
   provenance, authorized CLI state, backup metadata, and restore evidence.
   A successful backup unit is not proof of a restorable database. Do not carry
   historical event counts forward as live measurements.
3. **Authorization assurance:** `Authz` enforces actor/authorization options at
   the CLI seam, while the domain deliberately permits `:when_requested` calls.
   CLI lint and separate MCP checks are helpful but are not a universal
   deny-by-default domain boundary. A migration needs explicit internal actors
   and restricted-actor tests, not simply a configuration toggle. Declared
   `--as` remains attribution, not authentication.
4. **Test isolation:** Several older shell regressions require a live service,
   discover production tasks, or default to an administrator name. Keep the
   new offline suite as the default; make live canaries explicit, scoped, and
   separately authorized. No live task mutation was used for this audit.
5. **Readiness and load:** Socket `/health` reports liveness only, and the
   request Task.Supervisor has no configured admission limit in Application.
   Add tested capacity limits and a separate bounded readiness probe before
   promising availability under load; the current audit did not load-test
   production.

Papa's `lean-ctx` allowlist initially refused `sprucegoose whoami --as codex`.
On explicit user instruction, `sprucegoose` was added to that allowlist without
removing the defaults. The identity check then reached the service and reported
`unknown actor "codex"`. No actor grants or live task corpus were verified, and
no other actor's identity was borrowed. Registering an appropriately scoped
agent identity remains separate from allowing the shell command.
