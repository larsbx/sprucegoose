# SpruceGoose remediation operator disposition

- Task: `tsk-20260807T201427Z-8a11f69f`
- Recorded: `2026-08-10T01:51:25Z`
- Specification: `SPEC-SPRUCEGOOSE-REMEDIATION-2026-08-07`
- Specification SHA-256: `0f44ae59b737443d114a05faff902b6bc259fc4bd142b757aa813373c854b8ce`
- Workflow: `sprucegoose-remediation-p0-p1-v1`

## Decisions

1. WS-08 uses option B. Workflow definitions and task definitions are descriptive templates. SpruceGoose remains the authority for identity, lifecycle, dependencies, and evidence. The definitions do not execute tasks. The implementation must not create a hybrid with two authoritative runtime graphs.
2. WS-10 items 1 through 3 are in scope. The socket-parent ownership, symlink, and mode checks; safe-path restriction; and truthful caller-attribution documentation are required. Item 4 is deferred while the deployment permits no mutually untrusted agents. Trust-domain expansion is blocked until one of the specified authenticated identity mechanisms is implemented.
3. WS-12 migrations are forward-only. Restore from a verified dump into an isolated database is the only recovery path. Documentation and receipts must not claim schema rollback.
4. MCP remains disabled for the full remediation period.

## WS-04 disposition

The materialized workflow disposition-skips `ws04-oauth-actor-binding` and `review-ws04` while MCP is disabled. The materialized task count is 23 for the 25-node descriptive workflow because those two conditional nodes were not admitted.

Re-enabling MCP is blocked until WS-04 is admitted and completed in full, including immutable OAuth-client-to-actor binding, foreign-key and uniqueness enforcement, display-name non-authority, refusal of unbound clients, DCR/CIMD disposition, immediate revocation behavior, browser consent-route coverage, all required RED/GREEN tests, and both independent reviews.

## Boundary

This disposition resolves the four section 8 decisions. It does not enable MCP, approve production promotion, authorize trust-domain expansion, or authorize rollback claims.
