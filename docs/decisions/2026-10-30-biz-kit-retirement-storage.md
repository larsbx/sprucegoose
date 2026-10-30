# SpruceGoose retirement and platform storage succession

Date: 2026-10-30 (America/Chicago).
Status: **Selected integration target; implementation and cutover gated.**

Shared contract: [biz-kit storage/consolidation ADR](https://github.com/larsbx/biz-kit/blob/adf9d7d7e03e80af650124ce0fdfd02a232cb9b3/docs/architecture/2026-10-30-postgres-event-log-redis-consolidation.md)
([PR #207](https://github.com/larsbx/biz-kit/pull/207)); financial boundary:
[hawala-core ADR 0007](https://github.com/larsbx/hawala-core/pull/57).
These records specify design, not runtime acceptance.

## Context

The [current-state record](../current-state.md) describes PostgreSQL/Ash task authority, certified history and governed release. The selected target is retirement after retained capabilities move to biz-kit. Current service authority does not move through this ADR.

## Decision

- Inventory retained task/blueprint rules, actors/grants, permits, artifact
  custody, terminal receipts and consumers. Map retained commands into typed
  signed biz-kit admission with stable IDs and provenance; retire exclusions.
- Preserve original ETF/JCS bytes, identities, stream links and verification
  rules. Imports cannot fabricate old participant signatures or reinterpret history.
- Keep one active writer. Existing authority markers, service/CLI and governed
  releases remain authoritative until verified handover fences actual old writes.
- Move retained queues/retries/schedules to the shared Redis worker, backed by
  durable intent and receipts. Then remove covered Oban, custom timers, shadow
  writes, duplicate registries, hosting, releases and compatibility delegates.
- Preserve current grants, permit roots, single-use execution and signer/executor
  isolation. Redis leases and artifact publication confer no deployment authority.
- Migrate dashboard, CLI, runtime and SOP consumers before disabling commands.
  This reopens retain-the-runtime decisions as a future retirement target,
  preserving historical acceptance and present live permissions.
- Task migration grants no Hawala financial scope. TB financial acceptance
  remains separate from task/business authority.

## Acceptance and rollout

- Characterize retained commands/refusals and compare migrated history/IDs at
  an anchored source revision; retain open work, permits and custody evidence.
- Race old/new writers, restore/restart and prove the old service stays fenced.
- Destroy Redis/replay work without duplicate effects or loss of cancellation.
- Run repository fast, governed-release and dependency gates with retained
  evidence before implementation acceptance; identify unrun checks explicitly.
- Record consumer switch, backlog drain, archive and rollback that preserves
  every new accepted event rather than restoring a stale writer.

Keep current permissions, services and durable owners until verified replacement,
recovery and single-writer cutover. Recorded historical acceptance does not certify
new adapters. A documentation merge alone moves no live authority.

## Source contracts

[Kernel/ledger decisions](2026-09-08-kernel-and-ledger-shape.md), [certified history](../certified-ledger.md) and [deployment domain](../deployment-domain.md).
