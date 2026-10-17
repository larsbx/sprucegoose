# Project audit — 2026-09-08

> **Remediated 2026-09-08.** All findings below except C-04 (partial), A-04
> (partial), A-01, A-02, A-03 and A-05 are closed; see
> [`../audit-remediation-plan-2026-09-08.md`](../audit-remediation-plan-2026-09-08.md)
> for what was done and
> [`../decisions/2026-09-08-kernel-and-ledger-shape.md`](../decisions/2026-09-08-kernel-and-ledger-shape.md)
> for the four architectural decisions the rest turn on. The findings are left
> as written: an audit that gets edited to match the fix stops being evidence
> that the fix was needed.
>
> On PostgreSQL 18.6 GA, on a host with no `/home/admin-papa`: **422 tests, 0
> failures**, clean compile, no drift, dependency gate green.

**Verdict:** the delivered engineering is strong and the *transactional* story is
sound. The *constitutional* story is not: the kernel that the v0.2 remediation
was supposed to produce exists as a pure module with no caller outside its own
test, its decision procedure derives nothing, and the roots that production
events actually bind are digests of SpruceGoose's own source and planning
documents.

Separately, three process defects mean the claims in this repository cannot
currently be re-verified by anyone: **CI cannot pass**, **CI could only ever pass
on one host**, and **the schema cannot be created on any released PostgreSQL**.

This is a diagnosis, not remediation. Nothing in the working tree was changed
except the addition of this document.

## Scope and evidence

Audited commit `facc14a49cf09fa49210ed8008d1a557c719e660`, tree
`68062d0e50fa78bdf376339390e600690da9c20d`, on a clean working tree.

Evidence is from direct source inspection plus a reconstructed build. The
container had no Erlang, Elixir, or PostgreSQL, so the toolchain was built to
the repository's own pins:

| Component | Version | Provenance |
| --- | --- | --- |
| Erlang/OTP | 28.3.1 | built from `otp_src_28.3.1.tar.gz`, matching `.tool-versions` |
| Elixir | 1.19.5-otp-28 | `builds.hex.pm`, matching `.tool-versions` |
| PostgreSQL | 18.6 | PGDG `noble-pgdg`; the newest **released** major obtainable |

Commands actually run, and their results:

```text
mix deps.get                          exit 0   (76 advisory lines emitted)
mix deps.compile                      exit 0
mix compile --warnings-as-errors      exit 0   clean
mix format --check-formatted          exit 0   clean
mix hex.audit                         exit 1   41 advisories, 8 HIGH
MIX_ENV=test mix ecto.migrate         exit 1   → exit 0 only after stubbing one migration
mix test                              407 tests, 16 failures, 8 excluded
mix test --only separate_sessions     8 tests, 1 failure
mix ash_postgres.generate_migrations --check   exit 0   no drift
```

**Not verified.** No access to Mama, the live database, the Forgejo instance,
the artifact CAS, the `artifact-signer` identity, or any production evidence
directory. Every claim below about production behaviour is inferred from source
and is labelled as such. The reconciliation counts, replay parity, canary
results, and backup/restore receipts recorded in `docs/current-state.md` are
neither confirmed nor contradicted here.

**Correction carried forward.** The repository documents production as
PostgreSQL **19** Beta 2 (`README.md`, `docs/current-state.md`,
`ops/mama-authority/recovery/README.md`). The operator states it is PostgreSQL
**29** Beta 2. One of the two is wrong; see D-07.

## What holds up

These were inspected and found sound. They should survive any remediation.

- **The Ash authorization seam.** `SpruceGoose.Authz` making `actor!/0` *raise*
  rather than default, enforced by `test/authz_lint_test.exs`, is the right
  answer to `authorize :when_requested`. `Scope.of/1` refuses an unresolvable
  scope instead of defaulting. `HasRole` fails closed on every unmatched
  branch. `Readable` filters rather than refuses, with the zero-grant case
  reasoned about explicitly. The moduledocs argue their own trade-offs
  honestly.
- **Database-level immutability.** Triggers refusing update/delete on certified
  events, outcome receipts, permits, and runtime shadow snapshots put the
  guarantee below the application, where it belongs. The
  transaction-local `sprucegoose.projector_write` flag is a genuinely good
  pattern for a projector-owned materialization.
- **Content-addressed intake.** `Artifacts.Store` bounds size, refuses
  non-regular files, opens `:exclusive`, syncs, chmods `0440`, and re-verifies
  on collision. `ContentID`/`CertifiedEvent` correctly exclude delivery
  metadata from identity.
- **Typed effects.** `DerivationPermit` has an action enum and no command
  field. The Oban job carries a permit ID and nothing else. `handler_for/1`
  allowlists.
- **Migration hygiene.** `mix ash_postgres.generate_migrations --check` is
  clean: the snapshots and the resources agree.
- **Zero compiler warnings under `--warnings-as-errors`, and clean formatting**,
  across 110 files.
- **The CI script's own design.** Workspace-mutation detection via
  before/after SHA-256 snapshots, crash-dump detection, absolute-path
  assertions, and refusal of a dirty worktree are better than most release
  pipelines. Its problem is that it cannot run (D-01), not that it is weak.
- **Operational honesty in places.** `ops/mama-authority/recovery/README.md`
  already states plainly that the migration set "has no supported GA
  PostgreSQL target today" and that "the beta2 rehearsal must not be
  promoted."

## Findings

Severity: **Critical** blocks the claim outright · **High** invalidates a
documented guarantee · **Medium** a real defect with a bounded blast radius ·
**Low** correctness or clarity debt.

### A — Constitutional kernel

#### A-01 · Critical · The constitutional kernel has no caller

`SpruceGoose.Kernel.Constitution` — the whole Phase 3 deliverable, the answer
to audit finding F-01 — is referenced from exactly one file:

```text
$ grep -rn "Constitution\." lib test | grep -v kernel/constitution.ex
test/constitutional_path_test.exs:9:   Constitution.authorize(roots(), request())
... (21 more lines, all in that same test file)
```

Same for the reference adapters: `Kernel.Memory.ArtifactStore` and
`Kernel.Memory.EventLedger` are reached only from `test/kernel_ports_test.exs`.

Nothing in the CLI, the shadow ledger, the projector, the derivation executor,
or any Ash action calls into it. `docs/current-state.md` says "The deployed
kernel also provides one deterministic, content-addressed path from an exact
ontology version through … an unexecuted `EffectIntent`." The module ships in
the release; no code path reaches it. "Deployed" and "in the artifact" are not
the same claim, and the document does not distinguish them.

#### A-02 · Critical · `Constitution.authorize/2` decides nothing it is asked to decide

Every constitutional question is answered by a field the caller supplies:

```elixir
defp supported_claim?(%{claim_supported?: true}), do: :ok
defp accepted_evidence?(%{evidence_status: :accepted}), do: :ok
defp compatible_norm?(%{ontology_norm_compatible?: true}), do: :ok
defp sufficient_authority?(%{authority: :sufficient}), do: :ok
defp conflict_free?(%{conflicts: []}), do: :ok
```

`defined_predicate?/1` checks `request.predicate in request.defined_predicates`
— a caller-supplied atom against a caller-supplied list. It never consults the
ontology root. `bound_referent?/1` is the same shape. `current_grant?/2`
compares `roots.grant_epoch` to `request.grant_epoch_id`, both supplied in the
same call.

The module aliases only `Canonical` and `ContentID`. It reads no store, no
ledger, no grant table, no evidence. `authorize/2` is a total function of its
arguments.

What it therefore proves is: *"a caller asserted these premises, and here is a
tamper-evident content-addressed record of that assertion."* That is real
integrity value and it is not nothing. It is not the v0.2 requirement, which is
that the constitutional questions be **independently answerable**. The negative
tests in `constitutional_path_test.exs` (`:unsupported_claim`,
`:contested_evidence`, `:insufficient_authority`, …) all pass by flipping the
field that names the answer — they demonstrate the struct's field validation,
not a derivation.

The prior audit's own words apply unchanged: "Existing lifecycle validation is
deterministic application logic; it is not a substitute for those independently
answerable constitutional questions."

#### A-03 · High · Production roots are digests of SpruceGoose's own source

`priv/kernel/shadow-event-roots.json` supplies the roots bound into every
certified event. Verified against the tree at HEAD:

| Root | Source | Digest |
| --- | --- | --- |
| `ontology` | `lib/spruce_goose/kernel/constitution.ex` | `5a749225…` |
| `interpreter` | `lib/spruce_goose/kernel/constitution.ex` | `5a749225…` |
| `agent_charter` | `lib/spruce_goose/actors/registry.ex` | `11d5365d…` |
| `grant_epoch` | `lib/spruce_goose/actors/scope.ex` | `da82c82d…` |
| `policy` | `docs/authority-planes.md` | `30784cd5…` |
| `evidence_policy` | `docs/abstract-kernel-remediation-plan.md` | `8bc01ab6…` |
| `norm` | `/home/admin-papa/.openclaw/…/Systemwide SOP.md` | `560ad3ab…` |
| `schema` | migration-set digest | `684e3bd4…` |

Consequences, in order of severity:

1. **`ontology` and `interpreter` are byte-identical.** They are the same file.
   An event therefore cannot record "ontology version X, interpreted under
   interpreter Y" — the two roots carry one bit of information between them,
   and the distinction the kernel contract requires does not exist in the data.
2. **`evidence_policy` is the remediation plan.** That document describes work
   to be done. It is not an evidence-admissibility policy, and binding events
   to its digest means every edit to the plan re-roots subsequent history.
3. **Roots are never resolved.** No code path calls `ArtifactStore.get/2` or
   `verify/2` for any root. `Postgres.EventLedger.required_roots/1` checks only
   `~r/\Asha256:[0-9a-f]{64}\z/` — shape, not existence. A root is an opaque
   64-hex string that nothing can retrieve, so `verify` on it is not merely
   unimplemented, it is not possible with what is stored.
4. **`norm` lives outside the repository**, so the root set cannot be validated
   anywhere but one host. This is not theoretical; see D-02.
5. **The roots track the implementation.** Any edit to `constitution.ex`,
   `registry.ex`, `scope.ex`, `authority-planes.md`, the remediation plan, the
   SOP, or *any* migration changes what subsequent events bind, while
   `shadow-event-roots.json` is a hand-maintained file that must be updated in
   lockstep. Nothing enforces the lockstep at runtime. `ShadowEvents.roots/0`
   reads the file (or a path from `:shadow_event_policy_path`) and checks only
   that it parses and carries the right `schema` string — no digest, no
   signature, no pin.

F-06 said permits do not bind "ontology, norms, evidence policy, authority
root." They now bind eight strings with those names. The strings do not denote
those things.

#### A-04 · High · Phase 0 never landed

The remediation plan's Phase 0 exit gate is "Exact bytes, hashes, review
commit, successor/adoption identity, and Forgejo parity" for the v0.2 candidate
constitution plus a SpruceGoose amendment artifact.

`SPEC_Abstract_Deontic_Kernel_v0.2.md` (SHA-256 `b98ef904…`, per the v0.2
audit) is **not in the repository**. Neither is the amendment artifact. The
only file under `priv/kernel/` is `shadow-event-roots.json`.

So the baseline against which Phases 1–6 are claimed complete cannot be hashed
in-tree, and no reviewer working from this repository can check any invariant
against its actual text. Phases 1 through 6 are reported as delivered on top of
a Phase 0 that has no artifact.

#### A-05 · High · The certified ledger transports aggregate snapshots

`ShadowEvents.payload/2` builds an event whose `result` is the *entire*
mutated record, JSON-encoded:

```elixir
%{"command" => …, "outbox_event_key" => …,
  "result" => normalized,          # the whole Ash struct
  "shadow_schema" => "sprucegoose-mutation-shadow-v1"}
```

`TaskProjector.replay/3` consumes it as a wholesale replacement:

```elixir
{:cont, {:ok, put_in(acc, ["tasks", id], task), next}}
```

This is F-02's criticism of the outbox, reproduced inside the mechanism built
to remediate F-02: *"events carry aggregate snapshots rather than certified
transitions."* Three consequences follow:

- Replay is last-write-wins over snapshots. It does not fold transitions, so
  ordering is nearly load-bearing-free and a dropped event is invisible
  whenever any later snapshot for the same task survives.
- No event records *what changed* or *why*. The `command` name is the only
  transition information, and the projector ignores it beyond membership in
  `@task_commands`.
- The parity proof in `docs/current-state.md` ("Production rebuilt 708 tasks …
  with digest integrity, dual-read parity") is a real result, but it is the
  result that snapshot replay makes nearly tautological: replaying the last
  snapshot of each row reproduces the rows.

There is also no deletion path in the fold, so the projection can only ever
grow.

#### A-06 · Medium · Content identity is not independently verifiable

`Kernel.Canonical.encode/1`:

```elixir
{:ok, @version <> :erlang.term_to_binary(normalized, [:deterministic])}
```

The normalization is careful — sorted `{:object, pairs}` tuples, binary keys
only, floats and atoms rejected — and that removes the obvious sources of
nondeterminism. But the bytes that get hashed are Erlang External Term Format.
`:deterministic` fixes ordering within a given ERTS; it is not a stable,
specified wire format across OTP majors, and `minor_version` is not pinned.

`Kernel.EventLedger`'s own moduledoc says "ordered, immutable, **independently
verifiable** certified events." A non-BEAM implementation cannot recompute
these identities without reimplementing ETF. Given the surrounding argument
that certified events are historical authority, the canonical form should be a
specified byte format (RFC 8785 JCS, or a hand-rolled length-prefixed encoding)
whose spec fits on a page.

### B — Correctness and operations

#### B-01 · High · Every shadowed mutation serializes on one global lock

`ShadowEvents.run/2` always writes to stream `"authority:sprucegoose"`.
`Postgres.EventLedger.append_transaction/1` then takes
`pg_advisory_xact_lock(hashtextextended($1, 0))` on that stream name, and
allocates position with:

```sql
SELECT $1, COALESCE(max(stream_position), 0) + 1, …
FROM certified_events WHERE stream = $1
```

So all 25 shadowed verbs — across every project, roadmap, and workflow —
serialize behind a single advisory lock, and each append scans for `max()` over
a monotonically growing ledger. Throughput is one mutation at a time
system-wide, and append cost grows with history.

The lock is correct. The stream partitioning is the problem: one stream for the
entire system was a reasonable shadow-mode simplification and is not a
cutover-ready design. Phase 8 moves writers onto this path.

#### B-02 · Medium · Two paths notify before the shadow transaction can roll back

`apply_blueprint` (`executor.ex:952`) and `admit_derivation`
(`executor.ex:173`) both use `Authz.create_with_notifications/3` and then call
`Ash.Notifier.notify/1` directly. Both verbs are in `@shadowed_verbs`, so both
run *inside* `ShadowEvents.transaction/2`. If the subsequent certified-event
append fails — invalid roots, idempotency conflict, DB error — `Repo.rollback/1`
unwinds the mutation, but the notifications have already been dispatched.

`Authz.notify/1` and `Authz.destroy/1` handle this correctly, collecting
notifications and letting `ShadowEvents.transaction/2` fire them after commit.
These two sites bypass that discipline by using the
`*_with_notifications` variants, which never route through `notify/1`.

Currently **latent**: no Ash resource in the tree declares `notifiers`, so
`Ash.Notifier.notify/1` is a no-op. It becomes live the day anyone adds a
notifier.

#### B-03 · Medium · A failed receipt write loses the derivation outcome permanently

`Derivations.Executor.record_outcome/2` calls `Repo.rollback(reason)` on any
error. Since it is the only thing that writes a terminal receipt, and
`use Oban.Worker` sets `max_attempts: 1`, the sequence is: receipt write fails
→ transaction aborts → `{:discard, …}` → job gone. The permit is left with no
terminal receipt, and there is no CLI verb to re-enqueue it. Recovery requires
manual Oban insertion.

For a component whose stated purpose is "retain receipts and failure without
rewriting derivation history," losing the failure record is the wrong failure
mode.

#### B-04 · Medium · Failure receipts are written into an already-aborted transaction

```elixir
result =
  try do
    handler.run(permit)
  rescue
    exception -> {:error, Exception.message(exception)}
  ...
case result do
  {:error, reason} -> record_failure(permit, executor_id, message(reason))
```

`invoke_handler/3` runs inside the `Repo.transaction` opened by `execute/2`. If
the handler raises anything originating in PostgreSQL, the rescue catches it
but the transaction is already aborted — every subsequent statement fails with
`25P02`. So `record_failure/3` cannot write for exactly the class of failure
where a receipt matters most, and the outcome is B-03's silent discard.

The fix is a savepoint (`Repo.transaction` nested, or explicit `SAVEPOINT`)
around the handler call, or recording the failure in a fresh transaction.

#### B-05 · Medium · A failed CAS write poisons that content address permanently

`Artifacts.Store.create/3` opens the destination `:exclusive`, then writes,
then syncs, then chmods:

```elixir
{:ok, io} ->
  result = IO.binwrite(io, bytes)
  sync = :file.sync(io)
  File.close(io)
  with :ok <- result, :ok <- sync, :ok <- File.chmod(destination, 0o440), do: :ok
```

If `binwrite` or `sync` fails (ENOSPC, EIO), the partial file is left in place
and never removed. Every later `persist/2` for that digest takes the
`File.exists?` branch into `verify_existing/3`, which returns "content-addressed
artifact collision or corruption" — forever. The store has no way to heal it;
an operator must delete the file by hand, and the file is mode `0440` if the
chmod is what failed.

Write to a temporary name and `rename/2` into place. The rename is atomic and a
failed write leaves nothing behind. There is also a window between `open` and
`chmod` where the file sits at the process umask.

#### B-06 · Medium · Outbox event keys are compared lexicographically

`ShadowEvents.outbox_event_key/1`:

```sql
ORDER BY inserted_at DESC, event_key DESC LIMIT 1
```

`inserted_at` is a transaction timestamp, so it is constant for all rows a
single transaction produces, and the tie-break carries the decision. Event keys
have the shape `task:<uuid>:<lock_version>`, compared as text — so
`task:…:9` sorts above `task:…:10`, and the "latest" row is wrong once a task
crosses a digit boundary.

`ShadowEvents.status/0` then reconciles on `split_part(o.event_key, ':', 3)::bigint`,
which parses the number correctly. The two disagree. Sort on the parsed
`bigint` in both places.

#### B-07 · Low · A serialization failure rejects an otherwise valid mutation

`ShadowEvents.payload/2` runs the result through `Jason.encode/1`, and a
failure becomes `{:error, :noncanonical_shadow_result}` → `Repo.rollback`. The
mitigation is a hardcoded drop list:

```elixir
|> Map.drop([:__lateral_join_source__, :__meta__, :__metadata__,
            :__order__, :aggregates, :calculations, :task])
```

Failing closed is the right direction, but the guarantee is "no shadowed
resource ever returns an unencodable field," maintained by a literal list. Add
a relationship to any of the 25 shadowed verbs' resources and writes start
failing at runtime with a message that does not name the cause. Prefer an
explicit projection of the fields the shadow schema declares over a denylist of
the ones it cannot handle.

#### B-08 · Low · Mid-read mutation detection is second-granularity

`Artifacts.Store.stable?/3` compares size, inode, and `mtime`. `File.stat`
returns `mtime` at one-second resolution, so an in-place modification within the
same second that preserves size and inode is not detected. The v0.2 audit
credited the store with "detects mid-read mutation"; it detects most of it. The
receipt is still internally consistent (the digest covers the bytes actually
read and persisted), so the weakened claim is only "these bytes were the file's
content", which is inherently TOCTOU-bound.

#### B-09 · Low · A dead policy clause

`Derivations.OutcomeReceipt`:

```elixir
policy action_type(:read) do
  authorize_if(Readable)
  authorize_if(HasRole.derivation_executor())
end
```

`HasRole.match?/3` resolves its subject from `%{changeset: …}` or
`%{subject: %Ash.Changeset{}}` only. A read action carries a query, so the
second clause returns `false` unconditionally. It reads as "or a derivation
executor may read any receipt" and does nothing. Harmless today because
`Scope.role_matches?(_held, :reader)` makes any grant imply reader — but the
policy states an intent the code does not implement.

#### B-10 · Low · `Permit` retains vestigial execution columns

`docs/current-state.md`: "Permits no longer carry mutable execution progress or
terminal results." The resource still declares `state` (with a four-value enum
that can now only ever hold `:admitted`), `executor_id`, `evidence_digest`,
`artifact_digest`, `failure_reason`, `claimed_at`, `completed_at` — all
`public?: true`, so all exposed on the read surface including MCP. There is no
update action, so the statement is behaviourally true and the fields are dead.
Dead public fields on the authorization record are the wrong thing to leave
lying around.

#### B-11 · Low · The `reject_me` spike probe is still in production source

`lib/spruce_goose/events/event.ex`:

```elixir
# Q2 probe: can the (auto-generated) create action reject events before
# persistence? Simulates envelope verification-on-append.
validations do
  validate fn changeset, _ctx ->
    if Map.get(metadata, "reject_me") do
```

The v0.2 audit called this out by name under F-02 ("It even retains an
explicitly labeled spike validation (`reject_me`) in production source"). It is
unchanged, 28 commits later.

Adjacent: `Events.ClearAllRecords.clear_records!/1` unconditionally
`delete_all`s the `notes` table with no authorization gate. Nothing calls it
today, but it is a live destructive capability reachable through AshEvents
replay.

### C — Security

#### C-01 · High · 41 dependency advisories, 8 HIGH, several on the live surface

`mix hex.audit` (exit 1) at the locked versions. The ones that touch code paths
this project actually exposes:

| Package | Advisory | Why it matters here |
| --- | --- | --- |
| `ash 3.32.0` | `CVE-2026-82747` (M) | *"Ash.Policy.Authorizer returns records denied by a runtime read policy to any actor."* This is the `Readable` filter check — the entire read-authorization model. |
| `ash 3.32.0` | `CVE-2026-82749` (M) | `parent(...)` filter degrades to `IS NULL`, leaking scoped records. `Scope.@read_paths` is all relationship traversal. |
| `ash_authentication 5.0.0-rc.12` | `CVE-2026-65633` (H) | Purpose-limited JWT accepted as full bearer auth — directly on `BearerPlug`, the MCP gate. |
| `ash_ai 0.8.1` | `CVE-2026-81315` (H) | MCP DNS-rebinding origin check bypassed via spoofed `X-Forwarded-Proto`. This is the control that makes "loopback-only" safe against a malicious page in the operator's browser. `AshAi.Mcp.Router` is mounted at `/mcp`. |
| `ash_ai 0.8.1` | `CVE-2026-77956` (H) | EEx template evaluation of prompt content → RCE. |
| `ash_authentication_oauth2_server 0.3.0` | `CVE-2026-82753` (H) | Unauthenticated authorize requests create unbounded, never-expiring client rows. `oauth2_server_protocol_routes` is mounted unauthenticated by design. |
| `ash_sql 0.6.5` | `CVE-2026-78691` (L) | Unescaped backslash → LIKE wildcard injection. |

Not applicable, checked: `CVE-2026-82746` (`Ash.update_many/4` skips policies) —
`update_many` is not used anywhere in `lib` or `test`. `ash_postgres`
`CVE-2026-78699` (`rename_tenant`) — no multitenancy.

Mitigating: the MCP endpoint is opt-in (`SPRUCE_GOOSE_MCP_ENABLED`),
loopback-bound with the bind address deliberately not env-configurable, and
gated behind an immutable client-ID→actor-ID map that ignores registration
metadata. `ActorPlug` is well built. The residual risk is that four of the
HIGH findings are in the layers *underneath* those controls.

#### C-02 · High · The Forgejo verifier never cross-checks what it fetches

`ForgejoVerifier.verify/3` makes three API calls and cross-checks exactly one
field — `body["sha"] == commit`:

1. `GET /git/commits/{commit}` — the response carries the commit's declared
   tree SHA. The code pattern-matches only on `"sha"` and **discards the tree**.
   (`test/forgejo_blueprint_verifier_test.exs:96` even puts
   `"commit" => %{"tree" => %{"sha" => …}}` in the fixture; nothing reads it.)
2. `GET /git/trees/{commit}` — the entries are re-hashed into a git tree object
   by `git_tree_id/1`. That recomputation is never compared against the tree
   SHA from step 1, so it has no reference to be wrong against.
3. `GET /contents/{path}?ref={commit}` — the returned bytes are SHA-256'd
   directly. They are never checked against the blob SHA the tree lists for
   that path (`sha1("blob " <> size <> "\0" <> bytes)`), and the path is never
   walked through the tree.

So `source_tree` and `manifest_digest` are both derived from server-supplied
data, with nothing binding them to each other or to the commit. A Forgejo
instance that is compromised, misconfigured, or impersonated returns a
"verified" blueprint whose recorded tree and digest are internally consistent
and arbitrary.

The README's claim is: *"Blueprint registration independently reads the commit,
tree, and path bytes through Forgejo."* It reads them. It does not
independently verify them, and the two checks that would make it do so are
available from data the code already has in hand.

This matters more than it would elsewhere, because `blueprint apply` and
`task instantiate` are the *only* admission paths for new work — `task add` and
`inbox promote` are retired. It is the trust root of the whole admission story.

Mitigating: HTTPS with an owner-only token over a Tailscale network. Real
defence in depth; not the stated property.

Related: `:forgejo_api_url` is set in no config file, only in the test. So
production runs on the hardcoded default in `forgejo_verifier.ex:141` —
`https://ubuntu-8gb-hil-1.tail2188e6.ts.net:8448/api/v1`. Also, `fetch_bytes/6`
sets `receive_timeout: 10_000` but no response size cap.

#### C-03 · Medium · The only authentication boundary is never asserted by the application

The CLI socket is a fully privileged admin API: any process that can connect
can pass `--as <any actor>` and act as them. There is no authentication beyond
filesystem permissions — which is a defensible design for a local operator
tool, and `docs/authorization.md` is candid about what a declared actor proves.

But the application never establishes or checks that boundary:

- `CLI.SocketPath` verifies the path is a socket or absent. It does not check,
  set, or refuse a directory mode.
- The `0700` guarantee comes from `RuntimeDirectoryMode=0700` in the systemd
  unit — an operational control, outside the release.
- `config/runtime.exs:102`:
  ```elixir
  runtime_dir = System.get_env("XDG_RUNTIME_DIR", "/run/user/#{System.get_env("UID", "")}")
  ```
  `UID` is a bash shell variable, not an exported environment variable. With
  `XDG_RUNTIME_DIR` unset the fallback resolves to `/run/user/`, and the socket
  path becomes `/run/user/sprucegoose/cli.sock`.

So a service started outside its systemd unit, or with `SPRUCE_GOOSE_CLI_SOCKET`
pointed anywhere, degrades its sole authentication boundary silently. `stat` the
socket directory at startup and refuse to bind if it is group- or
world-accessible — the same `Bitwise.band(mode, 0o077) == 0` check
`ForgejoVerifier.token/0` already applies to the token file.

#### C-04 · Medium · The peer Ed25519 private key is stored in plaintext in the application database

`Identity.Local.provision_peer_key/0` generates an Ed25519 keypair and inserts
both halves into `spruce_goose_identity`. The moduledoc says retaining the
private seed "is mandatory so the peer can later prove ownership" — so it is
load-bearing for a future capability. It is protected by a trigger against
*modification*, and by nothing against *disclosure*: any database read, any
backup, any `pg_dump` carries it.

`docs/current-state.md` describes exactly the right custody model for the
*other* key: *"A root-managed `artifact-signer` identity holds the Ed25519
private key. The SpruceGoose/Oban executor cannot read or replace it."* This one
gets none of that. Note also that `peer_id/0` provisions the key as a side
effect of a read, with no authorization.

#### C-05 · Medium · Decompression bomb in the release validator

`ReleaseValidator.archive_payload/2`:

```elixir
case System.cmd("xz", ["-dc", path], stderr_to_stdout: true) do
  {tar_bytes, 0} -> {:ok, tar_bytes}
```

No output bound. `System.cmd/3` buffers the whole decompressed stream in
memory, and the tar members are then buffered again as
`{name, content}` pairs. This is the tool an operator runs against an archive
*before* trusting it; a small crafted `.tar.xz` OOMs the validator. Cap with
`xz -dc --memlimit` plus a byte ceiling, or stream.

#### C-06 · Low · No database TLS verification is configured

`config/runtime.exs` sets `ssl: ssl` (defaulting true) with no `ssl_opts`. There
is no `verify: :verify_peer`, no `cacerts`, no `customize_hostname_check`.
Whether the connection is actually verified depends on Postgrex and OTP
defaults rather than on anything stated here. For a system whose entire
authority lives in that database, pin it explicitly.

#### C-07 · Low · The compile-time artifact root is under `/tmp`

`config/config.exs:73` sets `:artifact_store_root` to
`"/tmp/sprucegoose-artifacts"`. `config/runtime.exs` overrides it — but the
`sprucegoose-direct` escript does not evaluate `runtime.exs`, so the recovery
artifact uses the `/tmp` default. `ensure_store_directory/1` calls
`File.mkdir_p` + `chmod`, both of which follow symlinks, in a world-writable
parent. Content addressing preserves *integrity* against a planted file; it does
not prevent an attacker from pre-creating the path or reading what lands there.

### D — Reproducibility and process

#### D-01 · Critical · CI cannot pass

`scripts/ci-governed-release` runs under `set -euo pipefail`:

```bash
mix deps.get
mix hex.audit          # ← exit 1, as of this audit
mix format --check-formatted
mix compile --warnings-as-errors
...
mix test
```

`mix hex.audit` exits 1 with 41 advisories. The pipeline aborts there, before
formatting, compilation, tests, the governed release build, provenance
inspection, validation, or the workspace-mutation check. Every gate downstream
of line 2 is currently unreachable.

Note that `mix deps.get` prints the same advisories and exits **0** — so the
advisories were visible in the log long before they became blocking.

The pipeline also runs only `when: - event: push` (`.woodpecker.yml`), so pull
requests get no gate at all.

#### D-02 · High · CI could only ever pass on one host

`test/shadow_event_append_test.exs:91`, in the *default* suite:

```elixir
assert roots["norm"] ==
         digest("/home/admin-papa/.openclaw/vaults/openclaw-system/10-sop/Systemwide SOP.md")
```

`digest/1` is `File.read!`. On any machine without that operator's home
directory, the test raises `File.Error`. Verified — it is one of the 16
failures below.

The test that validates the constitutional root set can therefore only be run
by one person on one machine. Combined with A-03 (`norm` is the only root whose
source is outside the repository), this is the concrete cost of putting a
constitutional artifact outside version control: the artifact is not reviewable,
and neither is the assertion about it.

Because the run aborts at that assertion, the `schema` root assertion
immediately below it (migration-set digest) never executes at all.

#### D-03 · High · The schema cannot be created on any released PostgreSQL

Verified on PostgreSQL 18.6, the newest released major available:

```text
** (Postgrex.Error) ERROR 42601 (syntax_error) syntax error at or near "PROPERTY"
    priv/repo/migrations/20260810143000_add_task_dependency_property_graph.exs
```

`CREATE PROPERTY GRAPH` (SQL/PGQ) exists only in an unreleased beta. So no
developer, no CI runner, and no disaster-recovery environment can stand up the
schema without that beta. `docs/current-state.md` names PG-as-beta an "explicit
production deviation … operationally verified but not a supported GA baseline";
what that phrasing understates is that it is not a production-parity problem,
it is a **build** problem — the project cannot be built or tested at all
without a beta database.

`ops/mama-authority/recovery/README.md` already states the correct conclusion:
"the reviewed migration set has no supported GA PostgreSQL target today …
Production must either wait for a supported … GA artifact … or separately
redesign and review the property-graph migration." That decision is still open,
and it is now blocking more than cutover.

For the rest of this audit the migration was stubbed locally (uncommitted,
reverted afterward) to reach the suite.

#### D-04 · Medium · The concurrency suite is never run, and has drifted

`test/test_helper.exs:1` — `ExUnit.start(exclude: [:separate_sessions])`. CI
runs plain `mix test`, so the eight `:separate_sessions` tests never execute
there. They cover exactly the claims the audit trail leans on hardest: genesis
races, concurrent certified appends holding one contiguous position, ledger
recovery, runtime-shadow concurrency, grandfathered baseline acceptance.

Run explicitly, one already fails:

```text
1) test concurrent Genesis requests on separate database sessions admit one
   complete actor (SpruceGoose.ActorsSeparateSessionsTest)
   assert length(grants) == 7
   left:  8
   right: 7
```

`Registry.grant_all/1` iterates `Role.values()`, which now has eight members
(`:author` among them). The assertion was written for seven and nobody noticed,
because nothing runs it. The test is *correct* about the invariant it cares
about (one actor, one genesis winner, all grants from `"genesis"`); it is stale
about the count.

#### D-05 · Medium · The documented escape hatch for those tests is broken

`config/runtime.exs:8` switches the pool to `DBConnection.ConnectionPool` when
`SPRUCE_GOOSE_TEST_DOGFOOD=true` — the only mechanism for running against a
real pool. But `test/test_helper.exs:3` calls
`Ecto.Adapters.SQL.Sandbox.mode/2` unconditionally, so the flag crashes the run
before a single test loads:

```text
** (RuntimeError) cannot invoke sandbox operation with pool DBConnection.ConnectionPool.
    test/test_helper.exs:3: (file)
```

Guard the `Sandbox.mode/2` call on the configured pool.

#### D-06 · Low · A wall-clock assertion that fails under load

`test/cli/socket_plug_test.exs:54` asserts a 200 ms request timeout returns in
under 250 ms. Under the full suite it measured 301 ms and failed; run in
isolation it passed three times out of three. A 50 ms margin on a scheduler
that is running 400 other tests is not a margin.

#### D-07 · Low · Deployment specifics in source, and a version the docs disagree on

Absolute paths from one deployment are compiled in as defaults:
`/home/admin-papa/.openclaw/…/Systemwide SOP.md` (`config.exs:81`,
`runtime.exs:19`), `/home/admin-papa/.config/sprucegoose/forgejo-read-token`
(`runtime.exs:78`, and again in `forgejo_verifier.ex:112`), and the Forgejo
base URL (C-02). The README claims Twelve-Factor conformance and specifically
that "dependencies and configuration remain explicit"; factor III wants these
out of the source.

And the PostgreSQL version: `README.md`, `docs/current-state.md`, and
`ops/mama-authority/recovery/README.md` all say **19** Beta 2 (the recovery
README dates that claim to 2026-08-11 and cross-references PG 18.4 as
then-current GA). The operator states production runs **29** Beta 2. Whichever
is correct, the tree disagrees with the live system, and every version claim in
those three documents needs reconciling in one pass.

## Status of the v0.2 audit findings

| v0.2 finding | Claimed phase | Actual status |
| --- | --- | --- |
| F-01 constitutional kernel absent | 3 | **Open.** Module exists; no caller (A-01); derives nothing (A-02). |
| F-02 no certified EventLedger | 5 | **Partial.** Real append-only ordered ledger with DB-enforced immutability — a genuine advance. But it carries snapshots, not transitions (A-05), and the `reject_me` probe it named is untouched (B-11). |
| F-03 definitions do not license instances | 2 | **Closed.** `blueprint_revision_id` + `definition_key` bind instances; `task add` retired; grandfathering is explicit and not selectable. Weakened by C-02 upstream. |
| F-04 mutable aggregates are authority | 6 | **Partial and honestly labelled.** Projector, digest, parity, and direct-write refusal all exist. `docs/current-state.md` correctly declines to claim cutover. |
| F-05 artifact custody not a kernel port | 1 | **Partial.** `ArtifactStore` behaviour + typed `ContentID` exist; the production `Artifacts.Store` does not implement the behaviour, and no root is ever resolved through it (A-03.3). |
| F-06 authority decisions not version-bound | 3 | **Open in substance.** Permits and events now carry eight named roots; the names do not denote the things (A-03). |
| F-07 effect boundary incomplete | 4 | **Largely closed.** Bounded executor, permit-only input, no command field, allowlisted handler, immutable receipt + certified event committed together. Defects: B-03, B-04. `test` and `build_release` remain fail-closed, which is the right call. |
| F-08 evidence not epistemically modelled | 3 | **Open.** `Evidence`/`Claim`/`Justification` structs exist in `Constitution`; unreachable (A-01) and caller-asserted (A-02). |
| F-09 temporal/replay semantics missing | 3,6,7 | **Open.** `unexpired_grant?/1` compares two caller-supplied timestamps. No Epoch, no validity intervals, no historic constitutional selection. |
| F-10 docs and implementation at different maturity levels | 0,9 | **Open, and now inverted.** The old problem was docs *understating* structure. The current problem is `docs/current-state.md` describing a "deployed kernel" whose central module has no caller, and D-07's version drift. |

The "controls worth preserving" list from v0.2 was preserved. That part of the
plan worked.

## Recommended sequence

Ordered by dependency, not by severity.

1. **Unblock verification** (D-01, D-02, D-03, D-05). Nothing else in this list
   can be checked until CI runs on a machine other than Mama. Concretely: gate
   `mix hex.audit` on a reviewed allowlist so it blocks on *new* advisories;
   move the SOP into the repository or make the `norm` root a fixture; make the
   property-graph migration conditional on server version with a documented
   relational fallback; guard `Sandbox.mode/2`.
2. **Reconcile the documents with the system** (D-07, A-01, B-10). One pass over
   `README.md` and `docs/current-state.md`: fix the PostgreSQL version, and
   change "the deployed kernel provides" to state what is reachable from a
   request and what ships unreferenced. This is cheap and it is what stops a
   reader mistaking artifact presence for behaviour.
3. **Land Phase 0 properly** (A-04). Commit the v0.2 spec bytes and the
   amendment artifact. Until the baseline is in-tree, no conformance claim
   against it is checkable by a reviewer.
4. **Decide what a root is** (A-03). Either roots denote adopted constitutional
   artifacts retrievable through `ArtifactStore` — in which case
   `required_roots/1` should resolve and verify them, and `ontology` must stop
   being `interpreter` — or they are provenance digests of the running
   implementation, in which case rename them and drop the constitutional
   vocabulary. The present middle state is the one that misleads.
5. **Close the admission trust gap** (C-02). Two checks, both using data already
   fetched: recomputed tree id vs. the commit's declared tree SHA, and fetched
   bytes vs. the tree's blob SHA for that path.
6. **Assert the socket boundary in the application** (C-03), and fix the
   `XDG_RUNTIME_DIR` fallback.
7. **Fix the bounded-executor defects before Phase 7** (B-03, B-04). A
   savepoint around the handler, and a receipt write that survives a handler
   that poisoned the transaction.
8. **Re-stream the ledger before cutover** (B-01, A-05). One global stream and
   one global advisory lock is a shadow-mode simplification. Phase 8 moves
   writers onto it. Partition by project or workflow, and decide whether events
   carry transitions or snapshots *before* they become historical authority —
   that choice is not revisable afterwards.
9. **Then the smaller items**: B-02, B-05, B-06, B-07, B-09, B-11, C-04, C-05,
   C-06, C-07, D-04, D-06.

## Verification appendix

Full suite, PostgreSQL 18.6, property-graph migration stubbed:

```text
407 tests, 16 failures (8 excluded)
```

All 16 failures accounted for:

| Count | Cause | Finding |
| --- | --- | --- |
| 13 | `SpruceGoose.DependencyGraphTest` — `syntax error at or near "MATCH"` / `"PROPERTY"` | D-03 |
| 1 | `ActorsTest` scoped dependency-graph read — same cause | D-03 |
| 1 | `MigrationUpgradeTest` — `relation "information_schema.property_graphs" does not exist` | D-03 |
| 1 | `ShadowEventAppendTest` — `could not read file "/home/admin-papa/…/Systemwide SOP.md"` | D-02 |

`test/cli/socket_plug_test.exs` failed once in the full run and passed 3/3 in
isolation (D-06); it is not counted above and is not a defect in the code under
test.

Excluded group, run explicitly:

```text
mix test --only separate_sessions
8 tests, 1 failure (407 excluded)   # genesis grant count, D-04
```

Root digests recorded in `priv/kernel/shadow-event-roots.json` were recomputed
against the tree at HEAD. All six in-repo sources match. `norm` is
unverifiable here (D-02). `schema` was not verified — the assertion that would
have checked it is downstream of the one that raises.

Clean: `mix compile --warnings-as-errors`, `mix format --check-formatted`,
`mix ash_postgres.generate_migrations --check`.
