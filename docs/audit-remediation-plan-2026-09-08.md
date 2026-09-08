# Audit remediation plan — 2026-09-08

Remediates [`audits/2026-09-08-project-audit.md`](audits/2026-09-08-project-audit.md).

Companion to [`abstract-kernel-remediation-plan.md`](abstract-kernel-remediation-plan.md),
which stays the authority for kernel phase sequencing. This plan does not
renumber those phases. It orders the work that the audit found blocking or
unsafe, and it is explicit about which items are patches and which are
decisions that no patch can substitute for.

## Priority criterion

Ranked lexicographically, descending:

```text
priority(f) = ( blocks_verification(f), invalidates_cutover_input(f), severity(f) )
```

- **`blocks_verification`** — while this holds, no fix to anything else can be
  demonstrated. Ranks first because a remediation you cannot show is not a
  remediation.
- **`invalidates_cutover_input`** — the pending decision is the Phase 8
  authority cutover. A defect that makes that decision *unsafe* or that
  corrupts an input to it outranks a defect that is merely severe.
- **`severity`** — the audit's Critical/High/Medium/Low.

This deliberately puts two Criticals (A-01, A-02 — the kernel decides nothing)
*below* four process defects. The reasoning is in T4: A-01/A-02 are not a bug
to fix, they are a question to answer, and answering it while CI is red and the
schema will not build on a released database wastes the answer.

## The list

> **Execution status, 2026-09-08.** T0, T1, T2 and T5 are implemented and
> verified; R-11 and R-12 are implemented as far as their inputs allow; D-2,
> D-3 and D-4 are recorded in
> [`decisions/2026-09-08-kernel-and-ledger-shape.md`](decisions/2026-09-08-kernel-and-ledger-shape.md)
> as proposals awaiting owner sign-off, because each changes what future
> immutable history means. See **Outcome** at the end of this document.

| # | Item | Closes | Tier | Kind | Size |
| --- | --- | --- | --- | --- | --- |
| R-01 | Make `mix hex.audit` pass | D-01, C-01 | T0 | patch | S — **verified below** |
| R-02 | Adopt the SOP as a repository artifact | D-02, A-03(`norm`) | T0 | patch | S |
| R-03 | Drop the SQL/PGQ dependency | D-03 | T0 | patch | S — **~20 lines** |
| R-04 | Run the concurrency suite in CI | D-04, D-05, D-06 | T0 | patch | S |
| R-05 | Reconcile the documents with the system | D-07, A-01, B-10 | T1 | patch | S |
| R-06 | Cross-verify what Forgejo returns | C-02 | T2 | patch | M |
| R-07 | Assert the socket boundary in the application | C-03 | T2 | patch | S |
| R-08 | Make the bounded executor survive its own failures | B-03, B-04 | T2 | patch | M |
| R-09 | Partition the certified event stream | B-01 | T3 | **decision** | M |
| R-10 | Transitions or snapshots | A-05 | T3 | **decision** | L |
| R-11 | Specify the canonical form | A-06 | T3 | decision | M |
| R-12 | Land Phase 0 | A-04 | T4 | patch | S |
| R-13 | Decide what a root is | A-03 | T4 | **decision** | M |
| R-14 | Make the kernel decide, or rename it | A-01, A-02 | T4 | **decision** | L |
| R-15 | Debt | B-02, B-05–B-09, B-11, C-04–C-07 | T5 | patches | M total |

Sizes: S ≤ 1 day · M ≤ 1 week · L = scoped separately after its decision.

## Non-negotiable boundaries

Carried forward from the kernel plan, plus two the audit adds:

- No certified event is deleted, rewritten, or re-rooted by any item here.
  R-13 changes what *future* roots mean; it does not touch history. If a root
  redefinition would require re-rooting existing events, it is out of scope and
  needs its own governed transaction.
- Mutable workflow rows stay operational authority throughout. Nothing in T0–T3
  advances the cutover.
- R-01's dependency upgrade does not change any Ash policy, action, or
  resource semantics. If it does, it stops and becomes its own task.
- T0 items are the only ones that may land without the full gate suite passing
  first — because the full gate suite is what they restore. Each T0 item still
  carries its own exit gate below.
- No item here fabricates historical provenance, and no item relaxes a refusal
  to make a test pass.

---

## T0 — Restore verifiability

Nothing downstream is checkable until these four land. Target: one working day.

### R-01 · Make `mix hex.audit` pass

**Problem.** `scripts/ci-governed-release` runs `mix hex.audit` at line 2 under
`set -euo pipefail`. It exits 1 with 41 advisories, so every gate after it —
formatting, compilation, tests, the release build, provenance validation, the
workspace-mutation check — is unreachable.

**This was executed and verified during the audit.** The path is four steps,
and steps 1–3 are drop-in:

1. `config/config.exs` — add:
   ```elixir
   config :ash, :default_string_length_count, :codepoints
   ```
   Required by `ash 3.33.0`'s `RequireStringLengthCountConfig` transformer
   (itself the fix for `CVE-2026-82752`). SpruceGoose declares **zero**
   `min_length`/`max_length` constraints, so the choice is inert for its own
   resources; it is required because *any* loaded resource, including
   `ash_ai`'s, triggers the transformer.

2. `lib/spruce_goose/accounts/oauth_client.ex` — add the extension:
   ```elixir
   use Ash.Resource,
     ...
     extensions: [AshAuthentication.Oauth2Server.ClientResource]
   ```
   `ash_authentication_oauth2_server 0.3.1` refuses to compile without it while
   `cimd_enabled?: true`. This *is* the fix for `CVE-2026-82753` (unbounded
   never-expiring CIMD client rows). **No migration is required** — confirmed by
   `mix ash_postgres.generate_migrations --check`, exit 0.

3. ```sh
   mix deps.update ash ash_authentication ash_authentication_oauth2_server \
                   ash_postgres ash_sql igniter mint plug
   ```
   41 advisories → **6**.

4. The remaining 6 are all `ash_ai 0.8.1`, all `HIGH`/`MEDIUM`, and all blocked
   by the `~> 0.8` constraint. Two options, and this one is a real choice:

   | Option | Effect | Cost |
   | --- | --- | --- |
   | **A** — `ash_ai ~> 1.0` | 6 → 0 | `AshAi.Mcp.Router` surface changed across the major; `router.ex` and `mcp_auth_test.exs` need rework |
   | **B** — remove `ash_ai` and the MCP endpoint | 6 → 0, and deletes the whole OAuth/MCP attack surface | loses the MCP tool surface; `Web.*`, `Oauth2Server`, `Accounts.Oauth*` and their migrations become dead |

   **Recommended: B, unless the MCP surface is in use.** It is opt-in
   (`SPRUCE_GOOSE_MCP_ENABLED`, default false), and it carries four of the
   eight HIGH advisories plus the OAuth server's unauthenticated route surface.
   For a system whose stated posture is "CLI-first; nothing binds a port," an
   unused endpoint that pulls in an LLM toolkit is a poor trade. If it *is* in
   use, take A and schedule it as its own task — a major bump under a red CI is
   not a T0 change.

   Interim, if neither can land today: an allowlist keyed by advisory ID with a
   mandatory expiry date and a named owner, so `hex.audit` blocks on *new*
   advisories. Not a fix; a way to keep the other 12 gates running.

**Exit gate.** `mix hex.audit` exits 0 (or exits 0 with an allowlist whose every
entry has an unexpired date and an owner). `mix compile --warnings-as-errors`,
`mix format --check-formatted`, and `mix ash_postgres.generate_migrations --check`
all exit 0. Full suite failure set is unchanged from before the upgrade.

**Evidence already collected**, OTP 28.3.1 / Elixir 1.19.5-otp-28 / PG 18.6:

```text
after steps 1-3:
  mix hex.audit                                  6 advisories (was 41)
  mix compile --warnings-as-errors               exit 0
  mix ash_postgres.generate_migrations --check   exit 0   (no drift)
  mix test        407 tests, 15 failures — identical set, no new failures
```

The upgrade was applied, verified, and reverted. The working tree is unchanged.

### R-02 · Adopt the SOP as a repository artifact

**Problem.** `test/shadow_event_append_test.exs:91` — in the *default* suite —
does `File.read!("/home/admin-papa/.openclaw/…/Systemwide SOP.md")`. On any
other machine it raises, so the test that validates the constitutional root set
can only run on one host. It also aborts before the `schema` root assertion
below it, which therefore has never run anywhere.

**Do not** fix this by skipping when the file is absent. That makes the
assertion vacuous everywhere except the one host, which is the same defect with
more steps.

**Change.** The SOP is legitimately a deployment-owned document — it lives in
the openclaw-system vault and `scripts/vault-write-authorization.py`
re-implements `SopGate`'s rule against it. That is why `SYSTEMWIDE_SOP_PATH`
exists and should stay. But a root bound into immutable history cannot be a
file nobody else can hash. Split the two roles:

1. Adopt the exact governed bytes as `priv/constitution/systemwide-sop.md`,
   committed, with its declared `sop_id`/`version` frontmatter intact.
2. Root `norm` at *that* artifact's digest in
   `priv/kernel/shadow-event-roots.json`, and set `sources.norm` to the
   repository path.
3. The test digests the in-repo artifact. It now runs anywhere.
4. Add a boot-time check: the bytes at `SopGate.path/0` must digest to the
   adopted artifact's digest. On divergence, refuse to start the CLI service
   (or, if that is judged too strict for a running deployment, refuse every
   transition into `in_progress` and log the divergence loudly). This is
   strictly stronger than the test it replaces — it checks the *live*
   deployment continuously rather than one machine at CI time.

Step 4 is the point of the change. Steps 1–3 alone just move the file.

**Exit gate.** `mix test test/shadow_event_append_test.exs` passes on a machine
with no `/home/admin-papa`, and the `schema` root assertion executes for the
first time. A deliberately divergent `SYSTEMWIDE_SOP_PATH` is refused with a
message naming both digests. A version bump to the adopted artifact is a
reviewed commit that changes the `norm` root, visibly.

**Note.** This is also the first genuinely adopted constitutional artifact in
the repository — a down payment on R-12.

### R-03 · Drop the SQL/PGQ dependency

**Problem.** `priv/repo/migrations/20260810143000` needs `CREATE PROPERTY GRAPH`,
which exists only in an unreleased PostgreSQL beta. Verified on PostgreSQL 18.6:
`ERROR 42601 (syntax_error) syntax error at or near "PROPERTY"`. So no
developer, CI runner, or DR environment can create the schema at all. 14 of the
audit's 16 test failures trace here.

`ops/mama-authority/recovery/README.md` already frames the choice as "wait for a
GA artifact, or separately redesign and review the property-graph migration."

**Take the redesign. It is smaller than it looks.** SQL/PGQ is load-bearing for
exactly one query. `Workflows.Graph.@edge_rows` returns
`(predecessor_id, successor_id)` for one workflow; `@task_rows` is already plain
SQL; and every traversal — `blockers/1`, `impact/1`, `critical_path/1`,
`distances/2`, tie-breaking, bounding — is Elixir over those two result sets.
The property graph provides no traversal, no recursion, and no ordering. It
provides an edge list.

The relational equivalent, preserving the vertex-membership constraint the PGQ
`MATCH` enforces:

```sql
SELECT d.predecessor_id, d.successor_id
FROM task_dependencies d
JOIN workflow_tasks p ON p.id = d.predecessor_id AND p.workflow_id = $1::uuid
JOIN workflow_tasks s ON s.id = d.successor_id   AND s.workflow_id = $1::uuid
WHERE d.workflow_id = $1::uuid
```

The three-way `workflow_id` agreement is what
`test/dependency_graph_test.exs` "corrupted edge workflow metadata is excluded
like the relational authority" asserts, and it survives the rewrite unchanged.

**Change.** Replace `@edge_rows`. Add a forward migration dropping the property
graph where it exists (guarded on server version so it is a no-op elsewhere).
Retire `20260810143000` behind the same guard rather than editing applied
migration history. Delete the two tests that assert on the graph *object* — "the
PostgreSQL property graph exposes task dependency edges" and "all graph commands
return errors when the property graph is unavailable" — and keep every test that
asserts on graph *semantics*, unchanged. They are the specification, and they
already include the recursive relational oracle at
`test/dependency_graph_test.exs:113`.

**Exit gate.** Schema creates cleanly on PostgreSQL 18 GA. `mix test` runs with
zero property-graph failures on a machine with no beta database.
`docs/property-graph-queries.md` is rewritten or deleted. The three graph CLI
commands return byte-identical output on the production database before and
after — captured as a before/after comparison, not asserted from tests alone.

**Consequence worth stating.** This removes the *only* reason the project needs
an unreleased PostgreSQL. After R-03, `postgresql-ga-readiness-diagnosis`
becomes a straightforward GA upgrade rather than a blocked one.

### R-04 · Run the concurrency suite in CI

**Problem.** `test/test_helper.exs:1` excludes `:separate_sessions`; CI runs
plain `mix test`; so the eight tests covering genesis races, concurrent
certified appends holding one contiguous position, ledger recovery,
runtime-shadow concurrency, and baseline acceptance have never run in CI. They
back the strongest claims in `docs/current-state.md`. One has already drifted:
`ActorsSeparateSessionsTest` asserts 7 genesis grants; `Role.values()` has 8
(`:author` was added and nobody noticed, because nothing runs it).

The documented way to run them is also broken: `SPRUCE_GOOSE_TEST_DOGFOOD=true`
switches the pool to `DBConnection.ConnectionPool`, and `test_helper.exs:3`
then calls `Ecto.Adapters.SQL.Sandbox.mode/2` unconditionally and crashes
before any test loads.

**Change.**
1. Guard `Sandbox.mode/2` on the configured pool in `test_helper.exs`.
2. Fix the stale assertion — assert against `length(Role.values())`, not a
   literal, so the next role addition cannot silently invalidate it.
3. Add a second CI step: `SPRUCE_GOOSE_TEST_DOGFOOD=true mix test --include
   separate_sessions --seed 0 --max-cases 1`, against a separate database, as
   `ops/mama-authority/recovery/README.md:89` already documents.
4. `test/cli/socket_plug_test.exs:44` — the 250 ms bound on a 200 ms timeout
   fails under full-suite load (observed 301 ms) and passes in isolation.
   Assert the *ordering* (returns before the stalled request could have
   completed) rather than a wall-clock margin, or raise the bound to a
   multiple.

**Exit gate.** Both CI steps green. The concurrency step is not `allow_failure`.
A deliberately introduced ordering violation in the certified append path fails
the concurrency step.

---

## T1 — Stop claiming what is not true

### R-05 · Reconcile the documents with the system

Cheap, and it must precede the cutover decision, because that decision will be
made *from* these documents.

| Claim | Where | Reality |
| --- | --- | --- |
| "PostgreSQL 19 Beta 2" | `README.md`, `docs/current-state.md`, `ops/mama-authority/recovery/README.md` | Operator states 29 Beta 2. Whichever is right, the tree disagrees with the live system. Fix all three in one pass. |
| "The deployed kernel also provides one deterministic, content-addressed path…" | `docs/current-state.md` | `Kernel.Constitution` has no caller outside its own test. It ships in the release; nothing invokes it. Say that. |
| "Permits no longer carry mutable execution progress or terminal results" | `docs/current-state.md` | Behaviourally true. The resource still declares `state`, `executor_id`, `evidence_digest`, `artifact_digest`, `failure_reason`, `claimed_at`, `completed_at`, all `public?: true`. Drop the attributes (B-10) or say they are vestigial. |
| "Blueprint registration independently reads the commit, tree, and path bytes" | `README.md` | It reads them. It does not verify them (C-02). Correct the wording now; R-06 makes it true. |
| "detects mid-read mutation" | `docs/audits/2026-08-21-…` (F-05) | Second-granularity mtime; a same-second, same-size, same-inode write is not detected (B-08). |

**Exit gate.** No document in the tree asserts a property the audit found
unimplemented. `docs/current-state.md` remains the only page describing live
state.

---

## T2 — Close what makes cutover unsafe

### R-06 · Cross-verify what Forgejo returns

**Problem.** `ForgejoVerifier.verify/3` makes three API calls and cross-checks
exactly one field (`body["sha"] == commit`). It discards the commit's declared
tree SHA, recomputes a tree id from a separately-fetched listing with nothing to
compare it against, and hashes the `contents/` bytes without checking them
against the tree's blob SHA. So `source_tree` and `manifest_digest` are both
derived from server-supplied data with nothing binding them to each other or to
the commit.

This is the trust root of the entire admission story — `task add` and
`inbox promote` are retired, so `blueprint apply` / `task instantiate` is the
only path by which new work enters the system.

**Change.** Two checks, both from data the code already has in hand:

1. In `fetch_tree/5`, keep the commit object's declared tree SHA
   (`body["commit"]["tree"]["sha"]` — the test fixture at
   `test/forgejo_blueprint_verifier_test.exs:96` already supplies it and
   nothing reads it). Refuse unless `git_tree_id(entries) == declared_tree_sha`.
2. In `fetch_bytes/6`, walk `path` through the tree to its blob entry and
   refuse unless
   `sha1("blob " <> byte_size(bytes) <> "\0" <> bytes) == entry["sha"]`.
   For a nested path this needs a subtree fetch per segment, or one
   `recursive=1` call — note that `encode_entries/1` sorts on `entry["path"]`
   and silently produces a wrong root hash if handed recursive output, so
   recursive entries must be used for the blob lookup only, never for the
   tree-id recomputation.

Also bound the `contents/` response size (`receive_timeout` bounds time, not
bytes), and move `:forgejo_api_url` out of the source default at
`forgejo_verifier.ex:141` into configuration.

**Exit gate.** Refusal tests, using the existing injected-request seam
(`:blueprint_http_request`), for: a tree listing that does not hash to the
declared tree SHA; bytes that do not match the tree's blob SHA; a path absent
from the tree; a mismatched commit SHA (already covered). Then re-verify one
existing production BlueprintRevision end-to-end and confirm the recorded
`source_tree` and `manifest_digest` are unchanged — if they change, the stored
provenance was wrong and that is its own governed finding.

### R-07 · Assert the socket boundary in the application

**Problem.** The CLI socket is a fully privileged admin API — any process that
can connect may pass `--as <any actor>`. Authentication is the socket's
filesystem permissions, which is a defensible design that
`docs/authorization.md` is candid about. But the application never establishes
or checks it: `CLI.SocketPath` verifies the path is a socket or absent and
nothing about its directory mode; the `0700` guarantee lives in
`RuntimeDirectoryMode=0700` in a systemd unit outside the release; and
`config/runtime.exs:102` falls back to `/run/user/#{System.get_env("UID", "")}`
where `UID` is a bash shell variable, not an exported environment variable —
so with `XDG_RUNTIME_DIR` unset the path becomes `/run/user/sprucegoose/cli.sock`.

**Change.** In `CLI.SocketPath.init/1`, before binding, `stat` the socket's
parent directory and refuse to start unless it is owned by the running uid and
`Bitwise.band(mode, 0o077) == 0` — the same check `ForgejoVerifier.token/0`
already applies to the token file. Remove the `UID` fallback: if
`XDG_RUNTIME_DIR` is unset and `SPRUCE_GOOSE_CLI_SOCKET` is not given, refuse
with a message naming both.

**Exit gate.** Service refuses to start on a group- or world-accessible socket
directory, with a message naming the directory and its mode. Refuses on an
unset `XDG_RUNTIME_DIR` with no explicit socket path. Starts unchanged under the
existing systemd unit.

### R-08 · Make the bounded executor survive its own failures

**Problem.** Two coupled defects in `Derivations.Executor`:

- **B-04.** `invoke_handler/3` rescues handler exceptions *inside* the open
  transaction, then calls `record_failure/3`, which writes in that same
  transaction. Any exception originating in PostgreSQL has already aborted it,
  so every subsequent statement fails `25P02` — the failure receipt cannot be
  written for exactly the class of failure where it matters most.
- **B-03.** `record_outcome/2` calls `Repo.rollback/1` on any error, and
  `use Oban.Worker` sets `max_attempts: 1`. So a failed receipt write discards
  the job, leaves the permit with no terminal receipt, and there is no CLI verb
  to re-enqueue it.

For a component whose purpose is "record success/failure receipts without
rewriting derivation history," losing the failure record is the wrong failure
mode.

**Change.**
1. Wrap the handler call in a savepoint (a nested `Repo.transaction`, or
   explicit `SAVEPOINT`/`ROLLBACK TO`) so a handler that poisons the
   transaction can be rolled back to a point where the receipt write still
   succeeds.
2. Separate the two failure classes. A *handler* failure is a normal terminal
   outcome and must commit a `:failed` receipt. A *receipt-write* failure is
   infrastructure and should retry, not discard — raise `max_attempts` for that
   path, or re-attempt the receipt in a fresh transaction.
3. Add an operator verb to re-enqueue a permit with no terminal receipt, gated
   on `derivation_executor`, refusing when a receipt exists (the
   `one_terminal_receipt_per_permit` identity already enforces the invariant).

**Exit gate.** Handler raising `Postgrex.Error` → `:failed` receipt committed
with the reason, and the certified `DerivationOutcomeCertified` event appended.
Receipt write failing under an injected fault → job retried, not discarded, and
no duplicate receipt on retry. A permit left without a receipt is recoverable
through the supported CLI.

### R-09 · Dependency advisories on the live surface

Folded into R-01 step 4. Tracked separately only if option A is taken, since an
`ash_ai` major bump is its own task with its own gates.

---

## T3 — Decide the ledger's shape before it becomes authority

These three are irreversible once certified events are historical authority.
They are **decisions**, not patches; each is specced as options with a decision
criterion, because picking one for you would be the same over-claiming the audit
objects to.

### R-09 · Partition the certified event stream

`ShadowEvents.run/2` writes every mutation to one stream,
`"authority:sprucegoose"`. `Postgres.EventLedger.append_transaction/1` takes
`pg_advisory_xact_lock` on that name and allocates position with
`COALESCE(max(stream_position), 0) + 1` over the whole stream. So all 25
shadowed verbs across every project serialize behind one lock, and append cost
grows with history.

Correct for shadow mode. Not viable as the write path for a cutover.

| Option | Ordering guarantee | Cost |
| --- | --- | --- |
| One stream (today) | total order over all mutations | one global lock; O(history) append |
| Per-project streams | total order within a project | cross-project causality unrecorded; projector must merge |
| Per-workflow streams | total order within a workflow | finest concurrency; cross-workflow task moves need a rule |
| One stream + sequence | total order, cheap position | `nextval` gaps on rollback ⇒ contiguity checks must change |

**Decision criterion.** What does the projector actually require? The current
`TaskProjector.replay/3` refuses non-contiguous history
(`next != prior + 1`), which is a stronger guarantee than a per-task projection
needs and is exactly what forces the global lock. Decide the projector's real
ordering requirement first; the partitioning follows from it.

Interlocks with R-10 — snapshots need less ordering than transitions do.

### R-10 · Transitions or snapshots

`ShadowEvents.payload/2` puts the entire mutated record in `payload.result`;
`TaskProjector.replay/3` consumes it as `put_in(acc, ["tasks", id], task)`. This
is F-02's criticism of the outbox ("events carry aggregate snapshots rather than
certified transitions") reproduced inside the mechanism built to remediate it.

Consequences already visible: replay is last-write-wins, so a dropped event is
invisible whenever a later snapshot survives; no event records what changed;
there is no deletion path so the projection can only grow; and the production
parity proof is close to tautological, since replaying the last snapshot per row
reproduces the rows.

| Option | What replay proves | Migration |
| --- | --- | --- |
| Keep snapshots | state is reconstructible | none; but the ledger is a state log, not a history, and should be named one |
| Certified transitions | state *and* its derivation are reconstructible | new event types per verb; projector becomes a real fold; existing events stay valid behind the grandfathered baseline |
| Transitions + periodic snapshots | both, with bounded replay | most work; standard answer |

**Decision criterion.** Does anything need to answer "why is this task in this
state" from the ledger alone? If yes, snapshots cannot ever answer it and the
choice is forced. If no, say so in `docs/current-state.md` and stop calling it a
history.

**This decision cannot be deferred past cutover.** Events written before it are
written in whichever shape is chosen now.

### R-11 · Specify the canonical form

`Kernel.Canonical.encode/1` hashes
`:erlang.term_to_binary(normalized, [:deterministic])`. The normalization is
careful — sorted `{:object, pairs}`, binary keys only, floats and atoms rejected
— but the hashed bytes are Erlang External Term Format: implementation-defined
across OTP majors, with `minor_version` unpinned. `Kernel.EventLedger`'s own
moduledoc promises "independently verifiable."

**Change.** Either specify a byte format whose spec fits on a page (RFC 8785
JCS, or a length-prefixed encoding defined in the module docs) and pin it in the
`"sprucegoose-kernel-v1\0"` prefix; or drop "independently verifiable" from the
port documentation and pin `minor_version` explicitly so at least the BEAM-side
guarantee is real.

**Exit gate.** A test vector file: inputs → expected digests, checked in, and a
second implementation (a ~50-line Python script in `scripts/`) reproducing every
one. If a second implementation cannot reproduce them, the claim is not true.

---

## T4 — The kernel

### R-12 · Land Phase 0

`SPEC_Abstract_Deontic_Kernel_v0.2.md` (SHA-256 `b98ef904…`) is not in the
repository, nor is the amendment artifact. So the baseline against which Phases
1–6 are reported complete cannot be hashed in-tree, and no reviewer working from
this repository can check any invariant against its actual text.

Commit both under `priv/constitution/`, unedited, with an adoption record
binding candidate to amendment. R-02 establishes the pattern.

Small, and it gates R-13 and R-14: you cannot decide what a root is against a
specification nobody in the repository can read.

### R-13 · Decide what a root is

Production roots are digests of SpruceGoose's own source and planning documents:
`ontology` and `interpreter` are byte-identical (both `constitution.ex`),
`evidence_policy` is the remediation plan, `agent_charter` is `registry.ex`.
None is ever resolved — `required_roots/1` checks the hex shape only, and no
code path calls `ArtifactStore.get/2` for a root, so `verify` on one is not
possible with what is stored.

| Option | Meaning | Work |
| --- | --- | --- |
| **Constitutional** | roots denote adopted artifacts, retrievable and verifiable through `ArtifactStore` | `required_roots/1` resolves and verifies; `ontology` must stop being `interpreter`; every root needs a real adopted artifact |
| **Provenance** | roots are digests of the running implementation | rename them (`source_digest`, `migration_set_digest`, …), drop the constitutional vocabulary, keep the integrity value |

**The present middle state is the one that misleads** — the names assert the
first, the data supports the second. Either is defensible; the current position
is not.

Whichever is chosen: `ontology == interpreter` must go. Two roots that are the
same file carry one bit between them and cannot record "ontology X under
interpreter Y," which is the distinction the kernel contract exists to make.

### R-14 · Make the kernel decide, or rename it

`Kernel.Constitution` has one caller: its own test. And every constitutional
question it appears to answer is a field the caller supplies —
`claim_supported?`, `evidence_status`, `ontology_norm_compatible?`, `authority`,
`conflicts`, and even `defined_predicates`/`bound_referents`. It aliases only
`Canonical` and `ContentID`; `authorize/2` is a total function of its arguments.

What it *does* prove — "a caller asserted these premises, here is a
tamper-evident content-addressed record of that assertion" — is real and worth
keeping. It is not the v0.2 requirement that the questions be independently
answerable.

**Two honest paths.**

- **Make it decide.** `authorize/2` takes an `ArtifactStore` and a
  `KernelContext`, resolves the ontology root, and derives
  `defined_predicates`/`bound_referents` *from the resolved ontology* rather
  than from the request. Evidence status comes from a stored evidence record,
  authority from `Actors.Scope`. Then wire one real admission path through it.
  Depends on R-13 choosing "constitutional", which depends on R-12.
- **Rename it.** Call it what it is — `Kernel.AssertionSeal` or similar —
  document that it seals caller-asserted premises, keep the negative tests as
  field-validation tests, and remove the constitutional-derivation claims from
  `docs/current-state.md`.

**Decision criterion.** Is there a specific decision the system must make that
today's Ash policies plus lifecycle validation cannot? If yes, that decision is
the vertical slice and path one is justified. If the honest answer is "not yet,"
path two is not a retreat — it is the difference between an artifact that
misleads a reader and one that does a smaller job correctly. The v0.2 audit's
own warning applies: do not relabel a partial mechanism as a kernel.

**Sequencing.** R-14 is last not because it matters least — A-01 and A-02 are
the audit's two Criticals — but because it is the only item whose cost is
dominated by a decision rather than by code, and because making that decision
while CI is red, the schema will not build on a released database, and Phase 0
has no artifact would waste the decision.

---

## T5 — Debt

Individually small, no dependencies, batchable. Ordered by risk:

| Item | Finding | Change |
| --- | --- | --- |
| Notification before commit | B-02 | `apply_blueprint` / `admit_derivation` route through `ShadowEvents.collect_notifications/1` instead of `Ash.Notifier.notify/1`. Latent today — no resource declares `notifiers` — live the day one does. |
| CAS write is not atomic | B-05 | Write to a temp name, `rename/2` into place. A failed write currently leaves a partial file that poisons that content address permanently, at mode `0440`, with no way for the store to heal it. |
| Lexicographic event keys | B-06 | `ORDER BY split_part(event_key, ':', 3)::bigint`, matching what `ShadowEvents.status/0` already does. Today `task:…:9` sorts above `task:…:10`. |
| Serialization denylist | B-07 | Project the fields the shadow schema declares instead of `Map.drop`-ing the ones Jason cannot encode. Currently a new relationship on any shadowed resource starts failing writes at runtime. |
| Mid-read detection | B-08 | Either narrow the claim, or add a post-read `open`+`fstat` inode/mtime/size comparison at finer resolution. |
| Dead policy clause | B-09 | Remove `authorize_if(HasRole.derivation_executor())` from `OutcomeReceipt`'s read policy — `HasRole` only resolves changesets, so it never authorizes a read. |
| Spike probe in production | B-11 | Delete the `reject_me` validation. Named in the v0.2 audit under F-02, unchanged 28 commits later. Also gate or delete `Events.ClearAllRecords.clear_records!/1`, which unconditionally `delete_all`s `notes` with no authorization. |
| Private key at rest | C-04 | `spruce_goose_identity.peer_private_key` is plaintext in the application database, protected against modification and not against disclosure. Apply the custody model `docs/current-state.md` already describes for `artifact-signer`. Also stop provisioning it as a side effect of `peer_id/0`. |
| Decompression bomb | C-05 | Bound `System.cmd("xz", ["-dc", …])` output. This is the tool run against an archive *before* trusting it. |
| Database TLS | C-06 | `ssl_opts: [verify: :verify_peer, cacerts: …, customize_hostname_check: …]`. Currently `ssl: true` with no options; whether the connection is verified depends on library defaults rather than anything stated. |
| `/tmp` artifact root | C-07 | The compile-time default is `/tmp/sprucegoose-artifacts`, and the escript does not evaluate `runtime.exs`, so the recovery artifact uses it. Make it required, with no default. |

---

## TDD contract

Unchanged from `abstract-kernel-remediation-plan.md`, with two additions the
audit forces:

1. Failing positive case and adversarial refusal cases first.
2. Smallest typed change.
3. PostgreSQL constraints for concurrency and direct-write bypass.
4. Manual review of generated migrations and snapshots.
5. Focused tests, format, `--warnings-as-errors`, full suite, migration drift.
6. Dogfood through the compiled socket CLI on a disposable database.
7. Deploy only with backup, rollback, health, and source parity proof.
8. **New —** every gate must run on a machine that is not Mama. A test that
   passes only on the production host has not run.
9. **New —** no item is complete while `mix hex.audit` is red, because nothing
   after it in the pipeline executes.

## Completion

T0–T2 complete when: CI is green end to end on a clean checkout of a machine
with no `/home/admin-papa` and a GA PostgreSQL; the concurrency suite runs there
too; every document claim matches observed behaviour; blueprint verification
refuses substituted trees and bytes; the socket refuses a permissive directory;
and a derivation that fails records that it failed.

T3–T4 complete when each decision is recorded — with its rationale and rejected
options — in a dated document, and the implementation and documentation both
match the decision. A decision deferred is fine and should be written down as
deferred. A decision made implicitly by code that ships is what produced A-02.

## Appendix — proposed TaskDefinitions

Governed admission requires a committed TaskDefinition. These are **proposed,
not applied**: extending a live project's manifest is an approver action through
`blueprint apply`, and the audit's own C-02 is that this admission path is the
system's trust root. Review, then apply deliberately.

```yaml
  - key: audit-remediation-2026-09
    name: Audit Remediation 2026-09
    workflows:
      - id: audit-remediation-v1
        name: Audit Remediation v1
        definition:
          schema_version: 1
          tasks:
            - id: restore-dependency-audit-gate
              kind: openclaw
              title: Restore the dependency advisory gate
              definition_of_done: mix hex.audit exits zero or blocks only on unexpired owner-attributed allowlist entries; the string-length-count configuration and OAuth client-resource extension are in place; warnings-as-errors compilation, formatting, migration drift, and the full suite pass with no new failures relative to the pre-upgrade baseline; the ash_ai disposition is recorded as an explicit upgrade or removal decision.
              depends_on: []
              input: {}
            - id: adopt-systemwide-sop-artifact
              kind: openclaw
              title: Adopt the Systemwide SOP as a repository artifact
              definition_of_done: The governed SOP bytes are committed under the constitution path and root the norm digest; the root-policy test passes on a host without the operator vault; the previously unreached schema-root assertion executes; a divergent deployment SOP path is refused with both digests named; no certified event is re-rooted.
              depends_on: []
              input: {}
            - id: remove-property-graph-dependency
              kind: openclaw
              title: Replace SQL/PGQ edge selection with relational authority
              definition_of_done: Workflow dependency edges are selected relationally with three-way workflow membership agreement; the schema creates on a supported PostgreSQL GA release; every graph semantics test passes unchanged and graph-object tests are retired; the three graph CLI commands return identical output on the production database before and after; property-graph documentation is corrected or removed.
              depends_on: []
              input: {}
            - id: run-concurrency-suite-in-ci
              kind: openclaw
              title: Run the separate-session suite in CI
              definition_of_done: The sandbox mode call is guarded on the configured pool; the genesis grant assertion derives its count from the role enumeration; a non-optional CI step runs the separate-session group against an isolated database; the socket timeout assertion no longer depends on a wall-clock margin; an injected ordering violation in the certified append path fails that step.
              depends_on: [restore-dependency-audit-gate]
              input: {}
            - id: reconcile-state-documentation
              kind: openclaw
              title: Reconcile documentation with observed behaviour
              definition_of_done: The PostgreSQL version, the reachability of the constitutional kernel, permit attribute vestigiality, blueprint verification strength, and artifact mid-read detection are corrected across README, current-state, and the retained audits; current-state remains the only page describing live state; no document asserts a property the audit found unimplemented.
              depends_on: []
              input: {}
            - id: cross-verify-blueprint-source
              kind: openclaw
              title: Cross-verify Forgejo commit, tree, and blob identity
              definition_of_done: The recomputed root tree identity is checked against the commit's declared tree, and blueprint bytes are checked against the tree's blob identity for the exact path; response size is bounded and the API base moves out of source; refusal tests cover mismatched tree, mismatched blob, absent path, and mismatched commit; one existing production BlueprintRevision re-verifies with unchanged tree and digest.
              depends_on: [restore-dependency-audit-gate]
              input: {}
            - id: assert-cli-socket-boundary
              kind: openclaw
              title: Assert the CLI socket authentication boundary in the application
              definition_of_done: The service refuses to bind unless the socket directory is owner-only and owned by the running user, and refuses an unresolvable runtime directory rather than defaulting; the message names the directory and mode; startup under the governed systemd unit is unchanged.
              depends_on: []
              input: {}
            - id: harden-bounded-executor-failures
              kind: openclaw
              title: Record derivation failures that originate in the database
              definition_of_done: A handler raising a database exception commits a failed outcome receipt and its certified event; a receipt write failure retries rather than discarding, without producing a duplicate receipt; a permit left without a terminal receipt is recoverable through the supported CLI under derivation-executor authority; permit and receipt immutability gates still refuse.
              depends_on: [run-concurrency-suite-in-ci]
              input: {}
            - id: decide-certified-stream-shape
              kind: openclaw
              title: Decide certified event partitioning and payload shape
              definition_of_done: The projector's actual ordering requirement, the stream partitioning, and the transition-versus-snapshot payload decision are recorded with rationale and rejected options in a dated document; the canonical encoding is either specified with reproducing test vectors and a second implementation or its independent-verifiability claim is withdrawn; no certified event is deleted or re-rooted.
              depends_on: [run-concurrency-suite-in-ci]
              input: {}
            - id: adopt-constitutional-baseline
              kind: openclaw
              title: Adopt the v0.2 candidate and amendment artifacts
              definition_of_done: The exact specification and amendment bytes are committed unedited with an adoption record binding candidate to amendment; their digests are reproducible from the repository alone; no existing root is redefined by this task.
              depends_on: [adopt-systemwide-sop-artifact]
              input: {}
            - id: decide-root-semantics
              kind: openclaw
              title: Decide whether roots are constitutional or provenance
              definition_of_done: The decision is recorded with rationale and rejected options; ontology and interpreter no longer share one digest; roots are either resolved and verified through the artifact store or renamed to provenance terms with the constitutional vocabulary removed; historical events retain their recorded roots unchanged.
              depends_on: [adopt-constitutional-baseline]
              input: {}
            - id: decide-kernel-disposition
              kind: openclaw
              title: Decide whether the constitutional kernel derives or seals
              definition_of_done: Either the kernel resolves its ontology root and derives predicates, referents, evidence status, and authority from stored state and is reached by one real admission path, or it is renamed to describe assertion sealing and every derivation claim is removed from the state documentation; the decision, its rationale, and the rejected option are recorded in a dated document.
              depends_on: [decide-root-semantics, decide-certified-stream-shape]
              input: {}
```


---

## Outcome — 2026-09-08

| # | State | Evidence |
| --- | --- | --- |
| R-01 | **done** | 41 advisories → 0 via `ash 3.33` string-length config, the OAuth `ClientResource` extension (no migration), in-range updates, and `ash_ai ~> 1.0` — all drop-in, MCP surface kept. `scripts/audit-dependencies` replaces bare `mix hex.audit` so the gate blocks on *new* advisories rather than staying red; verified to fail on unlisted, expired, and malformed entries. |
| R-02 | **done** | `priv/constitution/adopted.json` carries the reviewed SOP digest; `SopGate.verify_adoption/0` checks the deployed bytes at boot. The root-policy test runs on any host, and its `schema` assertion executed for the first time. |
| R-03 | **done** | SQL/PGQ replaced by a relational edge query with three-way `workflow_id` agreement. Schema migrates on PostgreSQL 18.6 GA. Graph semantics tests unchanged; the two graph-object tests retired. |
| R-04 | **done** | Concurrency suite runs as a non-optional CI step, 8/8. Genesis grant count derives from `Role.values/0`. Sandbox mode set through one guarded helper, so the dogfood pool works. Timing assertion no longer measures scheduler contention. |
| R-05 | **done** | README, `current-state.md`, and the recovery runbook corrected: PostgreSQL version, kernel reachability, permit vestigial fields, blueprint verification strength, ledger snapshot semantics. `property-graph-queries.md` → `dependency-graph-queries.md`. |
| R-06 | **done** | Commit → tree → subtree → blob, each recomputed and checked against an identity a prior response committed to. Recursive listings refused; response size bounded; API base and token path moved into configuration. Nine tests over an in-memory git repository with real object identities. |
| R-07 | **done** | `SocketPath.verify_directory/1` refuses a group- or world-reachable directory before binding. The `UID` fallback is gone. The service test no longer binds sockets into mode-1777 `/tmp`. |
| R-08 | **done** | Handler call savepointed, so a PostgreSQL exception still yields a typed failed receipt. Retries reserved for failures to *record* an outcome. `derivation reschedule` recovers a permit with no terminal receipt and refuses once one exists. |
| R-09 | **recorded** | D-2 — proposed: transitions, per-project streams, periodic snapshots. Not implemented: changes future history. |
| R-10 | **recorded** | D-2, same record. Carries a deadline: events written before it are written in the shape being decided. |
| R-11 | **done** | `minor_version: 2` pinned; independent-verifiability claim withdrawn at its source. Verified byte-identical to the previous default across seven sample terms, so no identity changed and no history was re-rooted. |
| R-12 | **partial** | The adoption mechanism exists and records the v0.2 specification and the amendment with `custody: "absent"` and the digest the v0.2 audit recorded. The bytes are not in the repository and cannot be synthesised; whoever holds them completes this by committing the file. |
| R-13 | **recorded** | D-3 — proposed: rename roots to provenance terms. `ontology == interpreter` must go either way. |
| R-14 | **recorded** | D-4 — proposed: rename the kernel to describe assertion sealing. |
| R-15 | **done** | B-02 notifications routed through the shadow collector; B-05 CAS writes atomic via temp-and-rename; B-06 outbox keys ordered numerically; B-07 failure names the offending field (the structural fix belongs to D-2); B-08 claim narrowed to what mtime resolution supports; B-09 dead policy clause removed; B-11 `reject_me` probe deleted and the replay wipe gated; C-04 key no longer minted as a read side effect (external custody remains open); C-05 xz bounded; C-06 `verify_peer` pinned; C-07 `/tmp` default removed. |

### Verification

On OTP 28.3.1 / Elixir 1.19.5-otp-28 / **PostgreSQL 18.6 GA**, on a host with
no `/home/admin-papa`:

```text
scripts/audit-dependencies                     PASS (1 accepted, 0 blocking)
mix format --check-formatted                   exit 0
mix compile --warnings-as-errors               exit 0
mix ash_postgres.generate_migrations --check   exit 0   (no drift)
mix test                                       422 tests, 0 failures
mix test --only separate_sessions              8 tests, 0 failures
```

Compare with the audit's starting position: 407 tests / 16 failures, schema
uncreatable on any released PostgreSQL, CI unable to reach its second gate, and
the concurrency suite unrun.

### What remains open

- **C-04** — the peer Ed25519 private key is still plaintext in the application
  database. External custody is a deployment change.
- **R-12** — Phase 0 has no artifact until the specification bytes are
  committed.
- **D-2, D-3, D-4** — three architectural decisions, each irreversible in the
  history it shapes. D-2 is the one with a deadline.
