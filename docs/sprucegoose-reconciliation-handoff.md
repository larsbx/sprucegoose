# SpruceGoose reconciliation handoff
Prepared 2026-09-09 UTC · Publication review 2026-09-10 UTC · Scope: source reconciliation, gate repair, and isolated acceptance evidence.

**Publication scope:** this documentation PR records the handoff only. It does not implement the prerequisite fixes or reconcile Forgejo and GitHub histories. GitHub main was rechecked before publication and remained at the baseline G below. After this document merges, G remains the historical code baseline; the documentation merge is not the reconciled candidate H.

**Disposition: ready for implementation handoff; not ready for release promotion.** Prepare a reviewed candidate that preserves both histories, fixes test configuration and dependency verification, and aligns the authoritative runbook with the repaired gate. Stop before deployment.

The September 9 evidence review used authenticated GitHub reads and bounded local shell fixtures. No Forgejo endpoint, production host, live service, database, deployment wrapper, or runtime client was accessed. That evidence-gathering pass made no repository writes. The subsequent documentation PR publishes this handoff with the user's authorization. The implementation changes below remain proposed work, not applied fixes.

## 1. Verified baseline

| Identity | Exact value | Interpretation |
| --- | --- | --- |
| GitHub main, G | `6a88239e71963a41856b03d2879f8f1c83caa434` | PR #4 merge; observed as main during this review |
| G tree | `b49bae167c0ded86162aadfa00afd87e699bbb8d` | Exact tree inspected |
| PR #4 head | `658f474bf904900fa1ae06eab363c6e34fd7ed83` | Test-database credential support |
| Pre-PR #4 main | `a6974b983e908e4ed79cd56defcecdd309c85df0` | Includes PR #3; insufficient as the new reconciliation target |
| Reported canonical snapshot, C₀ | `7284b7883537a022904f62ec6058d8b4f5bcfe41` | Now retrievable on GitHub; **not verified as current Forgejo main** |
| C₀ tree | `843482cbdd874f63c49e52795340a20907e75749` | Exact historical snapshot inspected |
| Common ancestor, B | `facc14a49cf09fa49210ed8008d1a557c719e660` | Comparison merge base |
| Reported CI branch | `2a6494bf` | GitHub lookup returns 422, “No commit found”; full identity unresolved |
| Reported running binary | `b54ec54a` | GitHub lookup returns 422; runtime identity remains a historical assertion |

[PR #4](https://github.com/larsbx/sprucegoose/pull/4) merged at **2026-09-09 13:32:33 UTC**. Its claim that none of the three reported commits exist on GitHub is partly superseded: [C₀ now resolves](https://github.com/larsbx/sprucegoose/commit/7284b7883537a022904f62ec6058d8b4f5bcfe41).

[Comparing C₀ to G](https://github.com/larsbx/sprucegoose/compare/7284b7883537a022904f62ec6058d8b4f5bcfe41...6a88239e71963a41856b03d2879f8f1c83caa434) reports **diverged: G is 8 commits ahead and 17 behind C₀**, counting merges. This is not a fast-forward synchronization problem.

Complete recursive trees show 13 file paths only in C₀, 8 only in G, and 42 shared paths with different blobs. Three paths changed on both sides since B:

| Path | Relationship | Required treatment |
| --- | --- | --- |
| `config/runtime.exs` | Different changes on both sides | Combine canonical Lifeline/Cron behavior with GitHub runtime/security/configuration changes |
| `mix.lock` | Different dependency changes | Reconcile the complete lockfile and run the repaired audit |
| `mix.exs` | Changed on both sides; identical final blob | Retain the shared result; matching constraints do not prove matching lockfiles |

These are review hotspots, not confirmed textual merge conflicts. Three-dot GitHub file comparisons describe changes since the merge base; the counts above come from direct tree comparison.

At G, GitHub returned no open PRs, zero Actions runs for the SHA, zero check runs, and no commit statuses. Combined status was pending with zero entries. This does not establish external Woodpecker status. PR #4’s reported 422 passing tests and 8 concurrency tests are historical evidence, not fresh results for a reconciled candidate.

## 2. Authority and changes to preserve

The repository’s [delivery architecture](https://github.com/larsbx/sprucegoose/blob/6a88239e71963a41856b03d2879f8f1c83caa434/docs/current-state.md) identifies **Forgejo as source authority**, with Woodpecker performing builds. Preserve that relationship.

The same document contains an August 22 live-state snapshot naming `3a2dc635…`, while PR #4 reports `b54ec54a` and PID 1261482. Neither is a current service observation. Do not relabel either as freshly verified.

Preserve canonical-side additions unless individually reviewed and explicitly superseded:

- `.sprucegoose/admission-bootstrap.yaml`, `.sprucegoose/dogfood.yaml`, and publication/norm-root candidate definitions in `.sprucegoose/project.yaml`.
- `docs/deontic-overlay/{SPEC_deontic_core.md,SPEC_precedence.md,TERMS.md}` and `priv/deontic/{deontic.exs,deontic.py,precedence.py}`. Preserve draft/non-adopted status.
- `ops/mama-authority/claude-hooks/*` and `ops/mama-authority/sprucegoose.service.d/30-bind-distribution-loopback.conf` as source artifacts; do not install them.
- Oban Lifeline whenever Oban is enabled, including with outbox disabled; Cron remains conditional on outbox. Preserve its canonical test.

`docs/property-graph-queries.md` is also only in C₀, but G intentionally replaces it with `docs/dependency-graph-queries.md`. Do not mechanically resurrect it.

Preserve GitHub’s PR #3 remediation, including source verification, socket checks, executor failure handling, dependency upgrades, SOP adoption artifacts, GA-compatible graph changes, and mandatory concurrency tests, plus PR #4 credential support. Review migration/root-file changes explicitly. Source reconciliation does not authorize a live migration, manifest application, norm adoption, or certified-history rewrite.

## 3. Reconciliation procedure

**Owner:** source maintainer with read access to both repositories. **Output:** one committed candidate and an exact comparison record. Work in a new disposable checkout away from the live installation.

1. Resolve the canonical clone URL from maintained repository configuration or owner-controlled records, not an old hostname. Read current Forgejo main as full commit **C** and tree; re-read GitHub main as **G′**. Record UTC time and remote identities without credentials.
2. Fetch complete histories into separate remote-tracking namespaces. Read applicable repository instructions before editing.
3. If C differs from C₀ or G′ differs from G, refresh this comparison and preservation inventory. Old object availability does not prove present branch state.
4. Branch from C and merge G′ with both histories retained. Resolve differences using `2. Do not force-push, reset canonical main to G, copy G’s tree wholesale, or blindly cherry-pick eight commits that include merges.
5. Implement ``4–5 and the runbook correction as separately reviewable commits.
6. Verify the exact resulting commit/tree in an isolated runner. Ref changes invalidate candidate evidence.
7. Prepare the canonical PR/diff and evidence manifest. Before future publication, inspect its hooks/CI: the tracked push workflow builds releases, and host-side automation was not inspected here.
8. After the canonical PR is eventually merged, mirror the **final canonical merge commit** to GitHub without rewriting history. Re-read both refs and require identical commit and tree. If either advanced, reconcile again.

Commands after fetching both repositories in the disposable checkout:

~~~sh
C=$(git rev-parse refs/remotes/canonical/main)
G=$(git rev-parse refs/remotes/github/main)
git rev-parse "$C^{tree}" "$G^{tree}"
git merge-base "$C" "$G"
git rev-list --left-right --count "$C...$G"
git log --left-right --cherry-mark --oneline "$C...$G"
git diff --name-status "$C" "$G"
~~~

`--cherry-mark` identifies potentially equivalent patches; it does not justify discarding a tree. The final candidate **H** should contain both fetched heads, unless a specific alternative is explicitly reviewed:

~~~sh
git merge-base --is-ancestor "$C" "$H"
git merge-base --is-ancestor "$G" "$H"
git rev-parse "$H^{tree}"
git status --porcelain=v1 --untracked-files=all
~~~

Keep `2a6494bf` and `b54ec54a` in an unresolved-identity register. Obtain full commit/tree identities from authorized repository records or existing release receipts without contacting the live service for this task. Do not fabricate full SHAs or assume ancestry from prefixes.

## 4. Prerequisite: normalize empty test-database overrides

The [PR #4 review finding](https://github.com/larsbx/sprucegoose/pull/4#discussion_r3958022981) remains applicable. The [pipeline loop](https://github.com/larsbx/sprucegoose/blob/6a88239e71963a41856b03d2879f8f1c83caa434/scripts/ci-governed-release#L53-L60) exports nonempty values but leaves previously exported empty values in the environment. [Test configuration](https://github.com/larsbx/sprucegoose/blob/6a88239e71963a41856b03d2879f8f1c83caa434/config/test.exs#L44-L61) defaults only absent values. An empty port reaches `String.to_integer("")`.

**Proposed implementation:**

- In `config/test.exs`, use one getter treating absent and exactly empty values as missing for database name, username, hostname, and port. Preserve nonempty values.
- Preserve password semantics: absent/empty means no password key; a nonempty password passes through unchanged. Never trim or print passwords.
- In the pipeline’s override loop, explicitly export nonempty values and unset empty ones.
- Validate nonempty ports as integers in 1–65535. Invalid supplied values must cause a clear configuration refusal, not a silent fallback.
- Keep the generated `spruce_goose_ci_<numeric-or-local>` database and isolated cleanup. Never borrow production credentials.

Suggested configuration helper:

~~~elixir
test_env = fn name, fallback ->
  case System.get_env(name) do
    nil -> fallback
    "" -> fallback
    value -> value
  end
end
~~~

Use the existing defaults: `spruce_goose_test`, `postgres`, `localhost`, `5432`. Validate the returned port before configuring Repo. Replace the shell loop’s conditional export with explicit if/nonempty/export, else/unset; keep the fixed list of four optional connection variables.

**Acceptance:** run environment cases in child processes, not by mutating shared environment in asynchronous tests. Read config using Config.Reader before booting an application/Repo.

| Case | Required result |
| --- | --- |
| Optional overrides absent | Previous defaults; no password key |
| Each override exported empty, then all empty | Same defaults; no empty username/hostname or port error |
| Empty DB name in direct test invocation | Default test DB; pipeline still generates its own CI DB name |
| Valid nonempty overrides | Exact username/hostname/password and parsed port preserved |
| Nonnumeric, zero, negative, or >65535 port | Clear refusal before any DB command |
| Disposable SCRAM PostgreSQL; correct test-only credentials | Full suite and separate-session suite pass |
| SCRAM; missing/wrong password | Nonzero; no release built; never PASS |
| Disposable trust PostgreSQL; variables absent/empty | Connection works without regression |
| Pipeline failure after DB creation | Only isolated test DB cleaned up; original failure remains nonzero |

This review’s Bash fixture confirmed that an exported empty port survives the current loop. Elixir/PostgreSQL acceptance tests were not executed here.

## 5. Prerequisite: make the audit wrapper fail closed

Use `scripts/audit-dependencies` as the acceptance-aware entrypoint, after repairing it. The [current wrapper](https://github.com/larsbx/sprucegoose/blob/6a88239e71963a41856b03d2879f8f1c83caa434/scripts/audit-dependencies#L19-L28) discards the underlying audit status and treats “no recognized advisory rows” as “no advisories.”

This review executed exact wrapper bytes with local git/mix stubs, without network, application, or DB access:

| Synthetic audit result | Current wrapper result | Finding |
| --- | --- | --- |
| Exit 42; service-unreachable error | Exit 0, “PASS (no advisories)” | Confirmed false PASS |
| Exit 1; advisory in unsupported format | Exit 0, “PASS (no advisories)” | Confirmed false PASS |
| Exit 1; recognized unlisted advisory | Exit 1 | Expected refusal |
| Exit 1; recognized allowlisted Decimal advisory | Exit 0, accepted | Existing acceptance behavior |

**Required contract:**

1. Capture output and underlying status separately.
2. Pin/document a supported Hex version and recognize its successful clean result and complete advisory-report format. Use structured output only if the supported version actually provides it.
3. Distinguish a completed audit with findings from tool/network/setup failure. Unknown status, incomplete/unrecognized report, or failure without a valid completed report must return nonzero. An accepted row plus an error must not become PASS.
4. Match advisory IDs literally. Require a single matching entry with nonempty owner/rationale and valid calendar expiry.
5. Fail unlisted, duplicate/ambiguous, malformed, and expired entries. Specify UTC expiry: accepted through the stated date, refused the next day.
6. Record accepted/blocking IDs, audit status, version, UTC date/time, and candidate lockfile/allowlist digests. Retain sanitized diagnostics. No `|| true` bypass at pipeline or runbook level.

The pinned [allowlist](https://github.com/larsbx/sprucegoose/blob/6a88239e71963a41856b03d2879f8f1c83caa434/.hex-audit-allowlist) contains **EEF-CVE-2026-32686**, Decimal 3.1.1, owner **lars**, expiry **2026-10-08**. Its “no fixed release” and reachability rationale are earlier repository assertions. This review did not revalidate the latest feed or available release. Reassess against H; never extend the expiry automatically or equate accepted findings with zero vulnerabilities.

**Acceptance matrix:** successful clean report; accepted-only; unlisted finding; accepted plus blocking; expired; expiry-day boundary; invalid date; missing owner/rationale; duplicate ID; malformed report; valid advisory plus fatal error; missing command; network/feed failure. Use deterministic report/date fixtures and a behavioral trace proving that failures prevent downstream compile/test/build.

Also repair [`test/release_ci_pipeline_test.exs`](https://github.com/larsbx/sprucegoose/blob/6a88239e71963a41856b03d2879f8f1c83caa434/test/release_ci_pipeline_test.exs#L28-L31): it still expects bare `mix hex.audit` before compilation. Change it to the wrapper, require both positions to exist before comparing them, and add behavioral refusal/ordering coverage. This stale assertion was found by source inspection; no ExUnit execution is claimed.

## 6. Align the actual runbook

**Confirmed:** [G’s pipeline](https://github.com/larsbx/sprucegoose/blob/6a88239e71963a41856b03d2879f8f1c83caa434/scripts/ci-governed-release#L40-L44) calls the wrapper; [C₀’s pipeline](https://github.com/larsbx/sprucegoose/blob/7284b7883537a022904f62ec6058d8b4f5bcfe41/scripts/ci-governed-release#L40-L44) calls bare `mix hex.audit`. Both Woodpecker definitions invoke `scripts/ci-governed-release` on push.

**Unresolved:** the deployment agent’s active runbook revision and actual command. Report wording cannot distinguish a stale pipeline, a separate runbook call, or a summarized failure label.

Locate the authoritative runbook and runner declaration through repository/document records. Record revision/path/digest and trace runbook → script → candidate tree. Do not inspect secret-bearing live environment files or probe the live service.

~~~sh
rg -n --hidden -g '!.git/**' -g '!deps/**' -g '!_build/**' \
  'mix[[:space:]]+hex[.]audit|audit-dependencies|ci-governed-release' .
~~~

Classify matches. Bare audit remains legitimate inside the wrapper and as labeled diagnostic output. Preserve historical audit excerpts; executable release instructions and present-tense criteria must reference the repaired gate.

**Replacement runbook text:**

> Use the reviewed candidate’s scripts/audit-dependencies as the dependency acceptance gate. Record its commit/tree, lockfile and allowlist digests, audit tool version, and dated result. Accepted findings require a named owner and valid review expiry. Unknown, incomplete, malformed, expired, or unlisted results block the candidate. Bare mix hex.audit may be retained as a diagnostic, but does not implement the acceptance policy. Execute scripts/ci-governed-release only in an isolated build/test environment. A successful result does not authorize deployment.

Correct present-tense contradictions in `docs/audit-remediation-plan-2026-09-08.md`: R-01 exit gate, generic completion rule, and proposed TaskDefinition wording still imply bare audit must be green, while the outcome section describes the wrapper. Keep original dated observations identifiable.

**Acceptance:** authoritative runbook revision/path supplied; invocation resolves to H’s repaired wrapper; blocked audit halts the candidate lane; accepted-only completed audit permits the next gate; no bypass fallback. If the active runbook is unavailable, mark **BLOCKED: runbook identity unavailable**.

## 7. Isolated verification and stop boundary

Run only after H is committed, scripts have been inspected, and the runner has no production service/socket, database, signer, deployment, or authority credentials. Use an independent disposable PostgreSQL instance/data directory.

Required evidence:

- Formatting, warnings-as-errors compile, migration drift check.
- DB override and audit acceptance matrices.
- Full `mix test` and `mix test --only separate_sessions --seed 0 --max-cases 1`; record actual counts.
- Lifeline/Cron configuration: Oban on/outbox off; both on; Oban off.
- Preservation/diff review, including lockfile, blueprints, draft overlays, and source-only operations files.
- Fresh `scripts/ci-governed-release` execution with unused absolute evidence/output paths, archive output outside the checkout, and unchanged source identity under documented generated-output exclusions.

Inspect the pipeline’s hard-coded `SPRUCE_GOOSE_TASK="tsk-20260813T140419Z-d8dbffc5"` before generating a real receipt. Do not falsely attribute this work to an unrelated old task. Supply a verified binding through a reviewed change or defer receipt generation as UNEXECUTED; never invent an ID.

The [release provenance contract](https://github.com/larsbx/sprucegoose/blob/6a88239e71963a41856b03d2879f8f1c83caa434/docs/release-provenance.md) distinguishes **artifact-only validation** from destination readiness. The pipeline performs one build and artifact-only validation. It does not prove double-build reproducibility, transferable-release status, destination migration parity, or deployment authorization.

**Stop with candidate, logs, proposed runbook revision, and source-parity evidence.** Do not invoke deploy/activate/rollback wrappers, service control, host installation, blueprint apply, runtime clients, production migrations, restores, or canaries.

## 8. Completion record

| Field | Evidence required |
| --- | --- |
| Source observations | UTC time; canonical/GitHub remote identity; C and G′ commit/tree |
| Reconciliation | B; counts; complete commit lists; file dispositions; H and tree |
| DB prerequisite | Patch revision and each acceptance result |
| Audit prerequisite | Patch revision, report/status fixtures, negative cases, acceptance review |
| Runbook | Authoritative path/revision/digest, invocation, reviewed change |
| Candidate checks | H, toolchain/Hex/DB versions, results/counts, sanitized logs |
| Later source publication | Final canonical merge SHA/tree; identical mirror readback |
| Live state | “Not accessed or changed”; historical reports explicitly historical |
| Open evidence | Full CI/running commit identities; unavailable runbook; unexecuted checks |

Use **PASS**, **FAIL**, **UNEXECUTED**, or **BLOCKED**, with evidence. Repository reconciliation can finish without proving the running binary’s identity; deployment readiness cannot be inferred from that narrower result.

**Work order:** observe current C/G′ → preserve/reconcile histories → fix DB overrides → repair audit and stale regression → align runbook → isolated gates → reviewable candidate → stop before deployment.

