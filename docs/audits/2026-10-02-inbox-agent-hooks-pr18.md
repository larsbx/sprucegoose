# Inbox agent-hook PR #18 audit — 2026-10-02

**Verdict: retain PR #18 in draft status.** The existing dependency gate blocks acceptance,
and this audit reproduced three additional gaps introduced by the hook change.
The recommendation path does not itself execute inbox, task, or deployment effects.

This is a dated audit of the exact PR #18 head below. This separate mirror
PR publishes documentation and archived diagnostics; it does not apply the
hook or remediate the findings. Forgejo remains source and merge authority;
Woodpecker remains canonical CI.

## Scope and source identity

PR: https://github.com/larsbx/sprucegoose/pull/18
Audited commit: f9d136bfa2679a4fb57363afd5dfa2a5b6353f1a
Audited tree: babe6800632c93b5c7d032099a43a7a1af6e84e3
Mirror base: c211ff67f244d92351a7bdf270987bbb619a6b0d
GitHub state observed during the audit: open, draft, mergeable, zero review threads; head unchanged.
Scope: all 28 changed files, related authorization/outbox code, tests, and gates.
Forgejo main and canonical Woodpecker state were not accessed or verified.

## Introduced findings

### F-01 · P2 · open · Optional triage refusal prevents the existing outbox delivery

Location: lib/spruce_goose/outbox/dispatcher.ex:35–41; failure handling:94–116.
https://github.com/larsbx/sprucegoose/blob/f9d136bfa2679a4fb57363afd5dfa2a5b6353f1a/lib/spruce_goose/outbox/dispatcher.ex#L35-L41

The new dispatcher calls the primary OUTBOX_HANDLER only after OutboxHook.deliver
returns :ok. An enabled hook whose configured proposer is revoked before a new
capture is scheduled returns invalid_capture_or_proposer. The primary handler
is skipped and the ordinary event consumes an outbox retry. Persistent refusal
eventually marks the original event failed without any primary delivery.

Reproduction: a disposable-database fixture revoked the dedicated proposer,
advanced event availability between attempts, and executed all 20 attempts.
The event ended failed, attempts=20, and the primary-handler message was never
received. No run was created. Advancing availability only compressed the existing
backoff schedule; it did not change dispatcher code or the retry budget.

Before this PR, perform/1 dispatched directly through the primary handler.
This coupling is new. It is conditional on explicitly enabling the pilot;
the default-disabled path did not exhibit the regression. Fail-closed refusal
of triage computation is appropriate, but need not suppress the unrelated
primary consumer. A revision should separate delivery obligations and retries,
preserving durable scheduling, idempotency, refusal evidence, and the original
at-least-once primary-handler contract. Add pre-scheduling revocation,
overprivilege/configuration failure, and exhausted-scheduling controls.

### F-02 · P2 · open · Direct Ash submit can accept a lease that expires during a row wait

Location: lib/spruce_goose/agent_hooks/store.ex:191–208 and 264–274.
https://github.com/larsbx/sprucegoose/blob/f9d136bfa2679a4fb57363afd5dfa2a5b6353f1a/lib/spruce_goose/agent_hooks/store.ex#L191-L208

prepare_submission checks valid_claim before eligible locks the inbox row.
If another transaction holds that row until the lease expires, the unchanged
pending capture is accepted after the wait and there is no subsequent lease
check in this direct action. The insert and delivery completion can commit.

Reproduction used independent database sessions, the configured bound proposer,
and the real Ash :submit action. A transaction held the inbox row; pg_stat_activity
confirmed the submission was waiting on transactionid. The holder released only
after the two-second lease had expired. The direct submit committed a proposed
result. A control through Store.finish with the same wait refused and left no
result: that wrapper reaches a second valid_claim check after its initial wait.

This narrows the finding to the documented direct-submit boundary; it does not
establish that the normal worker accepted this scenario. There is no new CLI or
MCP submission endpoint and lease tokens are not exposed by review output.
Revalidate the lease after potentially blocking eligibility checks, within the
same write transaction, or enforce the live lease predicate at persistence.
Add the separate-session direct-action expiry regression and wrapper control.

### F-03 · P2 · open · Terminal-evidence shape constraint accepts NULL fields

Location: priv/repo/migrations/20261002084348_harden_inbox_agent_hooks.exs:21–24.
https://github.com/larsbx/sprucegoose/blob/f9d136bfa2679a4fb57363afd5dfa2a5b6353f1a/priv/repo/migrations/20261002084348_harden_inbox_agent_hooks.exs#L21-L24

proposal_digest and reason are nullable. The proposed branch tests a digest
regex without requiring a non-NULL digest; refused/failed tests length(reason)
without requiring a non-NULL reason. PostgreSQL CHECK accepts an expression that
evaluates to NULL, as documented at:
https://www.postgresql.org/docs/16/ddl-constraints.html#DDL-CONSTRAINTS-CHECK-CONSTRAINTS

Reproduction inserted results bound to a real run's actor/context with raw SQL:
one proposed result with proposal={} and proposal_digest=NULL, and another
failed result with reason=NULL. Both inserts passed. Store.complete_delivery
then succeeded because its trigger checks for the existence of a result.
These incomplete rows can become immutable terminal evidence.

The supported Ash path validates the proposal and computes its digest; internal
failure writes supply a reason. This is a database defense/completeness gap,
not a demonstrated remote/CLI authority bypass. Ordinary SQL credentials remain
trusted under the documented pilot boundary. Explicitly require non-NULL fields
in their outcome branches, or require the whole shape predicate IS TRUE.
Add raw-SQL NULL controls without weakening existing immutable/binding triggers.

## Checked boundaries and limits

Authorization: opt-in is false by default; a canonical configured actor UUID,
active global proposer grant, and only reader/proposer roles are required.
Project-only and overprivileged actors refuse. AgentHooks authorizes by default;
review calls use Authz and global inbox read policies. The :submit action binds
the current proposer and computes actor/context/proposal fields internally.
Public input accepts only run_id, proposal, and the opaque claim argument.

Frozen input: schedule re-reads the persisted event and compares its identity
and payload. A versioned canonical run key deduplicates event/hook/version.
The envelope binds capture, event, compiled charter, configured actor, timeout,
handler name/code stamp, and context/configuration digests. Configuration and
capture content/state are checked at claim and submission. Immutable-run triggers
prevent update/delete. The handler MD5 is explicitly a VM code-change stamp,
not a source signature or attestation.

Transactions: schedule commits run, delivery, and Oban job together. Claim and
finish lock delivery rows and serialize with the registry's existing advisory
lock. Capture validation locks the inbox row in the write transaction. Computation
runs in a separate process with no inherited Authz actor and outside transactions.
The normal submission/result-completion pair rolls back together on injected
receipt-write failure. Before/after-action placement is consistent with Ash's
default transactional create; the direct lease-wait exception is finding 2.

Recovery: lease duration exceeds the configured timeout by 60 seconds, token
replacement prevents the old owner committing, concurrent claims snooze, and
expired claims can be reclaimed. The guard kills the adapter on timeout or worker
death. Recovery is at-least-once computation with one terminal result, not an
exactly-once provider call. Oban retry/lifeline integration needs the final
canonical full-suite evidence.

Revocation: current grants are re-read under the same transaction-scoped lock
used by Registry.revoke/disable. The real-session test shows a submission waiting
behind committed revocation refuses; capture resolution while submission waits
also refuses. Revocation prevents result persistence; it does not retract context
already given to an in-flight adapter or remote provider.

Evidence: result uniqueness, run actor/context binding, immutable update/delete
triggers, and delivery completion guards work on the supported path. This is
local pilot evidence, not constitutional certification or Senad+ attestation.
Finding 3 qualifies the database completeness claim.

Non-execution: the exact bounded output schema rejects extra executable fields.
drop/resolve/draft_task_definition are labels only; worker finish inserts a result
and completes delivery, and triage list/show only read. There is no apply command;
the MCP whitelist is unchanged. Draft task fields do not bypass existing admission.
Evidence references are unverified labels and are never fetched.

Trust boundary: an in-process compiled adapter is trusted BEAM/application code,
not a sandbox. No inherited Authz actor does not prevent such code from using
raw Repo calls, acquiring an actor, spawning children, or performing external I/O.
The charter forbids those behaviors but does not contain arbitrary local code.
Future adapter/provider selection therefore needs review and provider-side
limits/idempotency. This audit selected or contacted no provider and granted no
live authority.

## Existing dependency gate

GitHub Actions run: 36991492341
https://github.com/larsbx/sprucegoose/actions/runs/36991492341
Fast checks: success, job 110788499727.
Tests (scram-sha-256): failed, job 110788499907.
Tests (trust): failed, job 110788499995.
Both logs terminate with dependency-audit=FAIL and exit 1 before application
format/compile/migrate/test gates. Both report the same 21 unaccepted records:
2 in ash 3.33.1, 4 in mint 1.10.0, and 15 in ash_authentication 5.0.0-rc.13.
The wrapper is behaving fail closed. This is not evidence that the hook tests
failed in CI, nor does Fast checks establish that they ran.

mix.exs, mix.lock, .hex-audit-allowlist, audit wrapper/parser, Woodpecker definition,
and GitHub CI workflow are unchanged relative to the PR base. Identical lockfile
and acceptance inputs establish that this PR did not introduce these dependency
versions. Advisory reachability and fixed releases were not adjudicated here.
Treat dependency remediation as an independent prerequisite; do not silence,
skip, or broaden acceptance to make this hook pass.

mix.lock SHA-256:
fbd74f55b40cb2eed27173c4d97f0106106d7c1a6721645e504091071219b217
.hex-audit-allowlist SHA-256:
819a2ba4ceb344ae78212b7cf636482e122b7bcd43d73f89f6fd19344ba7c37f

## Local evidence from the audit

PASS: fresh disposable database migration and focused hook/outbox/authz/MCP suite,
47 tests, zero failures.
PASS: existing hook separate-session suite, three tests, zero failures.
REPRODUCED: three diagnostic tests confirming findings 1 and 3; zero unexpected
failures. Their success means the defect expectations were observed.
REPRODUCED: two real-session lease tests confirming finding 2 and the Store.finish
refusal control; zero unexpected failures.
PASS: independent scope and ordered 48-migration source-pin recomputation.
PASS: fresh formatting check, warnings-as-errors application compile, and
MIX_ENV=test mix ash_postgres.generate_migrations --check.
PASS: scripts/check-local, 25 Python tests; boot-free database configuration,
three tests; boot-free release pipeline regressions, six tests.
The audited checkout was unchanged during evidence gathering; diagnostics
were executed from outside that checkout. They are archived with this report
under `docs/audits/reproductions/`, outside the normal `test/` suite. SQL fixtures
used a new disposable database and dedicated test actors. The server was stopped after verification.

Runtime: Elixir 1.19.5 / OTP 28.3.1, PostgreSQL 16.15. PostgreSQL reused the prior
runner-adapted startup root check; SQL behavior was unchanged. Unix sockets are
unavailable here, so the disposable server used loopback TCP. This evidence is
not a stock-runner canonical gate PASS. The PR's previous 533-test restricted
suite, 11-test full separate-session result, rollback/reapply result, and three
Unix-socket EPERM failures remain historical local evidence, not new full-suite
results from this audit.

## Archived reproductions

The two files below contain **historical defect expectations** for exactly
`f9d136bfa2679a4fb57363afd5dfa2a5b6353f1a`. A successful run confirms that the
reported behavior was reproduced; it does not establish conformance. They are
outside `test/` and are not added to CI. A remediation should introduce inverted
regressions in the normal suite, rather than retain the defect expectations.

- [Outbox and NULL-evidence fixtures](reproductions/pr18-inbox-agent-hooks/pr18_audit_regressions_test.exs): three cases covering F-01 and F-03.
- [Lease race and worker control](reproductions/pr18-inbox-agent-hooks/pr18_lease_race_test.exs): two cases covering F-02 and its `Store.finish` refusal control.

Run these from a **separate checkout of the exact audited commit**, with the
repository's pinned toolchain and a new disposable PostgreSQL 16 database.
The audit-documentation checkout does not contain the unmerged hook. The fixtures
require explicit opt-in, the exact audited HEAD, and a database name beginning
`sprucegoose_pr18_audit_`. They create test actors/grants, and the separate-session
fixture truncates hook tables during isolated cleanup. Keep the instance free
of production services, credentials, providers, and other tests.

```sh
# In the separate checkout of f9d136bfa2679a4fb57363afd5dfa2a5b6353f1a:
audit_fixture_root=/absolute/path/to/audit-documentation-checkout/docs/audits/reproductions/pr18-inbox-agent-hooks
export MIX_ENV=test
export SPRUCE_GOOSE_PR18_AUDIT_REPRODUCTION=1
export SPRUCE_GOOSE_TEST_DATABASE=sprucegoose_pr18_audit_reproduction
# Supply host/port/user/password only for the new disposable PostgreSQL instance.
mix ecto.create
mix ash.migrate
SPRUCE_GOOSE_TEST_DOGFOOD=false \
  mix test "$audit_fixture_root/pr18_audit_regressions_test.exs"
SPRUCE_GOOSE_TEST_DOGFOOD=true \
  mix test "$audit_fixture_root/pr18_lease_race_test.exs" \
  --only separate_sessions --seed 0 --max-cases 1
```

The lease invocation uses `DBConnection.ConnectionPool` so the holder and
submission tasks see committed setup rows through separate PostgreSQL sessions.
Its fixture rejects the sandbox pool before creating rows. The first invocation
uses the default sandbox pool and rolls its fixture rows back.

For the published fixture copies, the opt-in/source/database setup assertions
were added and formatting applied. Those exact copies were rerun against the
audited head in a new disposable database: three defect cases and two lease/control
cases reproduced, with no unexpected failures. The publication worktree also
passed `scripts/check-local` (25 Python tests) and `git diff --check`. These
diagnostic commands are separate from the acceptance gate. They do not weaken `scripts/audit-dependencies`, establish
canonical CI, or authorize a build/deployment.

After review identified the missing pool setting in the command, the corrected
fixture copies reproduced all five cases again in a fresh disposable database.
The lease fixture also refused both cases at setup when the separate-session
setting was omitted, before creating fixture rows.

Mirror publication CI at `ed47808b7d484ddcaf61d18dae47c334c478971e`
([run 37012710881](https://github.com/larsbx/sprucegoose/actions/runs/37012710881))
passed `Fast checks` and the boot-free regressions. Both authentication matrix
jobs stopped at `dependency-audit=FAIL`: the same 21 unaccepted advisories
(two Ash, four Mint, fifteen AshAuthentication). The publication changes no
dependency manifest, lockfile, allowlist, or audit policy. The application
format/compile/migrate/test gates did not run; this failure is not evidence
that the documentation or archived fixtures failed those gates.

## Canonical acceptance still required

1. Read current maintained Forgejo main as full commit/tree C and observe the
   mirror candidate again. Reconcile from C without discarding canonical history
   or canonical runtime/Oban configuration. Record exact final candidate H and
   tree, parents, diff dispositions, and source parity. GitHub mergeability and
   its synthetic merge commit do not authenticate Forgejo main or authorize merge.

2. Review/revise the three introduced gaps and commit their negative controls.
   Regenerate/check Ash snapshots and recompute shadow-event scope and migration-set
   pins from H. Review both additive migrations and the compiled charter as source
   artifacts. Preserve existing certified history and the pilot's non-certifying
   status; do not adopt new live norms, grants, or providers.

3. On a stock isolated canonical runner use .tool-versions (OTP 28.3.1 and
   Elixir 1.19.5-otp-28), Hex 2.5.1, Python 3.9+, and disposable PostgreSQL 16.
   Record versions, registry/cache freshness, exact lockfile/allowlist digests,
   dated audit report/status, accepted/blocked IDs, and sanitized stdout/stderr.
   scripts/audit-dependencies must pass unchanged policy after independently
   reviewed dependency remediation. Unknown reports, expired/unaccepted advisories,
   or tool/network errors must still block all downstream acceptance.

4. Against H run scripts/check-local; boot-free database-configuration and
   release-pipeline regressions; mix format --check-formatted;
   mix compile --warnings-as-errors; and
   MIX_ENV=test mix ash_postgres.generate_migrations --check.
   Verify fresh migration, rollback of the two new migrations, and reapply in a
   disposable database. Run the focused hook/outbox/authz/MCP suite plus all newly
   added controls. Require unfiltered mix test, including Unix-socket tests, and
   mix test --only separate_sessions --seed 0 --max-cases 1 for the complete group,
   not just the hook's three tests. Record actual counts for H.

5. Run scripts/ci-governed-release --check on the exact clean candidate under
   both trust and SCRAM with correct disposable credentials. Record that missing
   and wrong SCRAM credentials fail nonzero and produce no release. The complete
   gate must not omit tests or bypass audit. Independent workspaces and unused
   evidence paths prevent stale-output reuse.

6. The tracked .woodpecker.yml is push-only and invokes
   scripts/ci-governed-release with its default --release mode. Require a successful
   canonical Woodpecker run tied to H, not a GitHub/local substitute. Supply a
   verified governing SPRUCE_GOOSE_TASK through the existing authority process,
   and fresh CI_EVIDENCE_DIR / external CI_RELEASE_OUTPUT_ROOT. Retain pipeline
   identity/configuration digest, exact commit/tree, logs/counts, migration inventory,
   archive and receipt hashes, embedded provenance, and successful artifact-only
   validation against that same H/tree. This builds evidence; it does not authorize
   deployment, live migration, provider activation, or merge.

Acceptance remains BLOCKED until the introduced findings are resolved, the
unchanged dependency gate passes, and canonical H-bound evidence is available.
During evidence gathering, no audit weakening, repository publication, live
migration/grant/provider, deployment, or merge was performed. This separate
documentation PR publishes the audit; it grants no canonical acceptance and
performs no remediation or live action.

## Canonical-obligation source references

docs/inbox-agent-hooks.md; docs/authority-planes.md; docs/dependency-audit.md;
docs/release-provenance.md; .tool-versions; .woodpecker.yml;
scripts/ci-governed-release; test/shadow_event_append_test.exs.
All source references above refer to the exact audited commit unless H is stated.
