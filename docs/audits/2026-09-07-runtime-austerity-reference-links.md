# Runtime austerity: task reference boundary

Status: local candidate patch; no production deployment or policy adoption.
Source baseline: `748e2d13b8e4386cf9e7b4757f572fb6980a3c17`.

## Verified finding

The operator actor `codex` can start tasks and add TODOs, but cannot attach a
repository reference. The live command below returned `Task.revise` forbidden:

```sh
./sprucegoose task link tsk-20260823T114850Z-15cb4952 repo /home/admin-papa/governance/sprucegoose --as codex
```

Both CLI reference commands call the general `Task.revise` action, whose
policy requires an approver. This couples routine evidence links to permission
to change the task definition. The candidate gives reference changes their own
Ash actions while retaining the policy on definition changes.

## Patch contract

1. **Affected invariants:** project scope, current actor grants, revocation,
   separation of task operation from definition revision, optimistic locking,
   and transactional certified-event recording. These are existing boundaries;
   this patch does not claim full SPEC_RUNTIME_AUSTERITY conformance.
2. **Old path:** CLI -> actor resolution -> scoped task read -> reference list
   construction -> approver-only `Task.revise(input)` -> resource validation ->
   database mutation and certified event in one transaction -> notifications.
3. **New path:** CLI -> actor resolution -> scoped task read ->
   `Task.link_reference` or `Task.unlink_reference` -> operator-or-approver
   policy -> reference-only input construction -> the existing validation,
   optimistic lock, transaction, event append, and notification path.
4. **Removed checks:** approver-only authorization for reference changes. No
   definition, receipt-custody, lifecycle, SOP, or dependency check was removed.
   Scoped operator-or-approver authorization protects this action instead.
5. **Relocated checks:** reference input construction now lives in the Ash
   action; direct authorized Ash callers receive the same field restriction.
6. **Authority artifacts:** none. Existing grants remain authoritative. No
   AuthorityEnvelope or grant expansion is introduced. The new actions accept
   no attributes; callers supply only kind and value arguments.
7. **Vectors:** executable cases in `test/actors_test.exs` cover operator
   link/unlink, reader refusal, wrong-project refusal despite read access,
   preserved non-reference input, forbidden input replacement, forbidden title
   revision, stale-write refusal, revoked-grant refusal, approver compatibility,
   exact whitespace, duplicate append, and removal of one duplicate. The full
   language-independent AuthorityEnvelope golden suite is still outstanding.
8. **Failure modes:** missing references and malformed reference lists fail;
   stale writes fail rather than overwrite a newer record; rejected policy
   checks prevent persistence. Links are evidence pointers, not verified
   artifact receipts, proof of authority, or permission to execute effects.
9. **Compatibility:** the live legacy operator refusal is reproduced. Its new
   allow is classified as LEGACY_BUG against the operator evidence-linking
   contract; this classification requires review before cutover. Approver
   reference results retain bytes, ordering, duplicate handling, and unrelated
   input. Existing CLI/database and certified-event regressions pass. This is
   bounded compatibility coverage, not full authority-class equivalence.
10. **Rollback:** restore the previous two CLI call sites and remove the new
    Ash actions/policy. No migration is required. Preserve all stored references
    and certified events. Rollback restores the operator refusal; it must not
    erase evidence already recorded.

## Verification

- Initial focused suite: 70 tests, zero failures.
- Full suite before the final byte-preservation test: 412 tests, one failure,
  eight excluded. `TransactionalOutboxTest` expects only a Cron plugin, while
  current configuration includes Lifeline and Cron. The failure reproduces
  alone. Both the test and configuration match HEAD and were not changed.
- Final focused suite, including certified-event append tests: 76 tests,
  zero failures, one excluded.
- Final compilation with warnings as errors, repository formatting, migration
  drift, and `git diff --check` all passed.
- No live candidate execution, compiled recovery-CLI dogfood, full migration,
  or deployment was performed. The full suite is not green.

## Migration state

Access is now valid. The administrator granted operator on `*` and an additional
project grant. This work uses only `openclaw-system`; grants were not changed.

The existing unassigned audit task `tsk-20260823T114850Z-15cb4952` was moved
through propose, queue, ready, SOP acknowledgment, and start. It remains an
audit task and does not claim production implementation authority. TODO
`todo-97683521325561b26d4b942b2dac6d9b` tracks M0. Migration request
`inbox-9d1beaf5e109c6b370f5f6218de72749` remains pending.

The complete M0 gate inventory and a governed implementation TaskDefinition
remain outstanding. This candidate addresses the observed reference-link
defect only; it does not remove other gates before their invariants are traced.
No roadmap, workflow, grant, or task definition was revised or self-approved.

Unrelated hook changes remain untouched. The earlier `post-audit` invocation
was blocked by lean-ctx's command allowlist. No handoff delivery is claimed.
The saved initial report records the blocked command; the hook never ran, so
it produced no retry token.

The existing remediation skill covers this repair pattern. No additional
session skill is proposed or installed.
