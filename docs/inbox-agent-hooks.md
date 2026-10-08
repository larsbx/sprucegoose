# Inbox agent-hook pilot

Forgejo is source and merge authority; Woodpecker is canonical CI. This pilot
starts from the GitHub mirror at `c211ff67f244d92351a7bdf270987bbb619a6b0d`.
The mirror candidate must be reconciled against current Forgejo main and checked
by Woodpecker before canonical acceptance. No live migration, grant, provider
connection, deployment, or merge is performed by this change.

## The first hook

An `inbox.captured` event is the first useful seam: it already commits with the
capture. The existing outbox dispatcher schedules an agent job in a short
transaction, then invokes its original `OUTBOX_HANDLER`. Agent work happens in
a separate Oban worker, outside transactions. Scheduling failure leaves the
event retryable; the existing handler is still delivered at least once.

| Record | Purpose | Authority |
| --- | --- | --- |
| `agent_hook_runs` | Frozen capture, event, hook version, charter digest, configured actor, adapter code stamp, configuration and context digests | Immutable input; no public create/update/delete action |
| `agent_hook_deliveries` | Lease token, expiry, attempts and completion | Internal delivery bookkeeping; never agent input or CLI output |
| `inbox_triage_results` | One proposed, refused or failed outcome per run | Immutable recommendation/evidence; no inbox, task, or deployment effect |

Run identity hashes the event key, hook ID and version using the existing
versioned canonical encoding. Duplicate delivery returns the same run; it does
not overwrite the input or schedule another job. The run, delivery row and job
commit together. Dispatched historical events are not automatically replayed.

The charter is the actual compiled bytes of
`priv/agent_hooks/inbox-triage-v1.json`. Context hashing includes that charter,
the captured text, event identity and configuration. The adapter's VM MD5 code
stamp detects ordinary code changes; it is not a source signature. The hashes
are integrity/provenance bindings for this local pilot, not constitutional
certification or Senad+ attestation. Existing certified history is not rewritten.

## Connecting an agent

Implement the `SpruceGoose.AgentHooks.Handler` behaviour in a compiled adapter:

```elixir
defmodule MyApp.InboxTriageAgent do
  @behaviour SpruceGoose.AgentHooks.Handler

  def propose(context) do
    # Use your existing agent client to send this frozen context and return
    # {:ok, proposal} or {:error, reason}. Apply provider-side I/O limits too.
    MyApp.AgentClient.triage(context)
  end
end
```

No model provider or credentials are assumed. The callback runs in a bounded
process without an `Authz` actor. It receives only the frozen context, including
the instruction to treat captured text as untrusted data. In-process adapters
are trusted application code, not sandboxed plugins: they must not acquire
domain authority, execute commands, delegate, or mutate SpruceGoose as part of triage.
Keep remote agents behind this data-only adapter contract.

In an isolated pilot instance, an existing registry administrator creates a
dedicated agent and grants only the global proposer role:

```sh
./sprucegoose actor add inbox-triage --kind agent --as registry-admin
./sprucegoose grant add inbox-triage --role proposer --scope '*' --as registry-admin
./sprucegoose actor show inbox-triage --as registry-admin
```

Use the returned immutable actor UUID, not its declared name. A global grant is
required because the inbox has no project ownership before triage. Project-only
grants refuse. Additional roles other than reader/proposer also refuse, so a
general operator or administrator cannot be reused as the pilot identity. The
grant is re-read under the registry's existing serialization lock before
computation and again before proposal persistence.

After review, configure the pilot instance explicitly:

```sh
OUTBOX_DISPATCHER_ENABLED=true
OUTBOX_HANDLER=YourExistingOutboxHandler
SPRUCE_GOOSE_OBAN_ENABLED=true
SPRUCE_GOOSE_INBOX_TRIAGE_ENABLED=true
SPRUCE_GOOSE_INBOX_TRIAGE_ACTOR_ID=<canonical-actor-uuid>
SPRUCE_GOOSE_INBOX_TRIAGE_HANDLER=MyApp.InboxTriageAgent
SPRUCE_GOOSE_INBOX_TRIAGE_TIMEOUT_MS=30000
```

The feature is disabled by default. Startup refuses enabled triage without Oban,
the dispatcher, a canonical UUID, a loaded `propose/1` adapter and a timeout
between 1 and 300000 ms. Runtime checks also require an active, suitably granted
actor. Adapter/configuration/charter changes invalidate frozen pending runs
instead of interpreting their captures under a different configuration.

## The exact proposal schema

Every key below is required, including nullable values. Unknown keys refuse:

```json
{
  "disposition": "draft_task_definition",
  "project_key": null,
  "workflow_key": null,
  "rationale": "This capture needs a diagnosis before executable work is admitted.",
  "uncertainty": "high",
  "evidence_refs": ["inbox:<capture-id>"],
  "draft_task_definition": {
    "title": "Investigate the captured issue",
    "description": "Review the capture and establish a reproducible diagnosis.",
    "task_type": "diagnosis",
    "task_kind": "openclaw",
    "acceptance_criteria": ["An operator reviews the evidence and proposed definition."]
  }
}
```

Dispositions are `drop`, `resolve`, and `draft_task_definition`. The first two
require a null draft. Drafts require exactly the five illustrated keys; task
types are task/diagnosis and kinds oban/taskflow/openclaw. These are suggestions,
not runner admission. Project/workflow keys are nullable slug recommendations;
their existence and suitability remain an operator review obligation.

Output is at most 16384 JSON bytes. Rationale is bounded to 4000 characters;
evidence references to 16 strings of 512 characters. Draft titles are at most
200 characters, descriptions 8000, and acceptance criteria 1–16 strings of
1000 characters. Uncertainty is low/moderate/high. Evidence references are
labels; the hook never fetches them or treats them as verified evidence.

## Review and failure handling

```sh
./sprucegoose inbox add "Investigate this captured issue" --as operator
./sprucegoose triage list --as operator
./sprucegoose triage show <run-uuid> --as operator
```

`triage list` returns the latest 50 run summaries and pending/terminal status.
`triage show` displays the frozen input and result. Both use normal Ash read
policies; a project-scoped reader cannot read this global inbox data. Lease
tokens are not exposed. There is no CLI apply command and the MCP whitelist
remains read-only and unchanged. An operator may resolve/drop the capture using
the existing inbox commands, or commit a TaskDefinition and use existing
blueprint/task admission. A recommendation never performs those operations.

Jobs accept exactly one opaque run UUID. A short row-locked claim grants a lease
longer than the configured computation timeout. Concurrent claims snooze; a
crashed worker's expired lease can be reclaimed. Worker death/timeout terminates
the adapter process. Computation is at least once after infrastructure failure;
the database accepts at most one terminal result. Provider-side idempotency may
use the frozen event/hook identity. Terminal failures are not model retries;
infrastructure/receipt-write failures use Oban's bounded retry budget.

Submission locks and rechecks the inbox row inside its write transaction. A
resolved/dropped/edited capture refuses; a revoked/disabled/overprivileged actor
or disabled/changed hook also refuses. An expired or replaced lease cannot
commit. The Ash submit action performs the same checks for direct callers and
requires the bound proposer identity; no caller may supply outcome authority,
actor identity, context digest, or executable fields. Refusals/failures are
internal audit writes licensed by the existing run, not effects delegated to
the agent. Raw SQL update/delete of input envelopes and results is refused by
database triggers; ordinary credentials and privileged database administration
remain the existing trust boundary.

The two additive migrations create the pilot records and protect evidence.
The candidate also refreshes the shadow source pins for the changed scope file
and migration set. This is a reviewed source artifact for future events, not an
adopted norm change or a rewrite of roots in existing certified events. Recompute
those pins against the final reconciled Forgejo candidate.

## Verification

Run against a disposable PostgreSQL 16 instance with the pinned Elixir/OTP:

```sh
MIX_ENV=test mix ash.migrate
mix test test/agent_hooks_test.exs test/transactional_outbox_test.exs \
  test/authz_lint_test.exs test/spruce_goose/web/mcp_auth_test.exs
mix test test/agent_hooks_separate_sessions_test.exs \
  --only separate_sessions --seed 0 --max-cases 1
scripts/check-local
```

Separate-session tests use genuinely separate connections, not a shared
transaction. They cover duplicate scheduling/claims, revocation while submission
waits on the registry lock, and resolution while submission waits on the capture
row. The focused suite covers rollback, exact output schema, configuration
changes, stale results, role/identity/lease refusals, timeout, worker death and
recovery, immutable records, and authorized CLI review. Full canonical acceptance
still requires the repository's dependency audit and Woodpecker checks.

Local review evidence on 2026-10-02, starting from the mirror baseline above:

| Check | Result |
| --- | --- |
| Formatting, compilation with warnings as errors, migration snapshot check | PASS |
| Fresh database migration; rollback and reapply of the two new migrations | PASS |
| Focused pilot/outbox/authz/MCP suite | 47 tests, 0 failures |
| Suite with `test/cli/socket_service_test.exs` omitted | 533 tests, 0 failures; 11 concurrency tests excluded by the normal profile |
| Complete separate-session suite | 11 tests, 0 failures |
| Fast Python/script checks | 25 tests, 0 failures |
| Earlier unfiltered suite | Three Unix-socket tests failed with `EPERM` in this execution environment |
| Dependency audit on the unchanged lockfile/allowlist | FAIL: 21 unaccepted advisories in existing Ash, Mint and AshAuthentication dependencies |
| Forgejo reconciliation / canonical Woodpecker run | UNEXECUTED |

The isolated local PostgreSQL 16.15 build accommodates this runner's mapped-root
UID restriction in its startup checks; its SQL engine is unchanged. Socket tests
and the complete gate must run again on an ordinary canonical runner. The
dependency gate was not bypassed or silenced, and this candidate is not a release
or a claim of canonical acceptance. Receipt-write failure injection also checks
that a failed completion write rolls the proposal back and permits a later retry.
