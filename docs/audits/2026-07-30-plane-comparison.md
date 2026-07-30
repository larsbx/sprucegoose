# SpruceGoose compared with Plane

Date: 2026-07-30 UTC  
SpruceGoose: `cefd077ca398001bc727f120b5e662ca393736c8` (`main`)  
Plane: `7564480cf73c7ea8b037c002f3fe6cfd2267367e` (`preview`)  
Twelve-Factor baseline: `655b020ac25eac8f912ccc845094ec16cdf6b30b`
(`main`)  
Governance task: `tsk-20260730T130949Z-dbbcac72`

## Verdict

SpruceGoose is already stronger than Plane at governed machine execution:
explicit admission, mandatory Definition of Done, SOP digest acknowledgment,
typed project/roadmap/workflow membership, fail-closed lifecycle transitions,
dependency gates, diagnosis evidence, transactional outbox delivery, and
immutable knowledge projection.

SpruceGoose materially lags Plane as a collaborative product-management
application. It has no browser UI, public API, identity/RBAC plane, comments,
attachments, notifications, cycles, modules, rich pages, analytics, or the
range of interactive layouts present in Plane.

The two systems therefore overlap at task tracking but are not substitutes
today. Plane is the stronger human collaboration surface. SpruceGoose is the
stronger governed execution authority.

## Capability matrix

Ratings describe the repository at the pinned commits, not roadmap intent.

| Area | SpruceGoose | Plane | Verdict |
|---|---|---|---|
| Project hierarchy | Typed Project → Roadmap → Workflow → Task hierarchy, validated on admission | Workspace/project hierarchy with broad product UI | SpruceGoose is stricter; Plane is easier to use |
| Work items | Titles, descriptions, DoD, state, priority, dates, assignees, labels, typed custom fields, TODOs | Rich-text work items, sub-properties, uploads, relationships, activity and collaborative editing | Plane ahead for people; SpruceGoose ahead for completion contracts |
| Lifecycle | Explicit fail-closed transition graph; wait/cancel reasons; predecessor and TODO completion gates | Configurable issue states and ordinary workflow transitions | SpruceGoose ahead for governance |
| Dependencies | Task and TODO DAGs; duplicate, self, cross-workflow and cyclic edges rejected, including database guards | Work-item relations and dependency-oriented planning | SpruceGoose ahead on enforced execution invariants |
| Boards and views | Kanban boards, state-bound columns, rank, saved filters | List, Kanban, calendar, spreadsheet and Gantt layouts; saved/shared views | Plane materially ahead |
| Intake | Inbox capture, triage, drop/resolve, governed promotion to a task | Intake for requests and triage through the product UI | Comparable concept; Plane ahead in UX |
| Sprints/cycles | None | Cycles with progress and burn-down | Plane gap: **high** |
| Modules/milestones | Workflow DAG exists, but no Plane-like modules or milestone planning model | Modules for breaking projects into scoped bodies of work | Plane gap: **high** |
| Roadmaps | Current resource contains only key, name and project membership | Interactive roadmap/product planning surface | Plane gap: **high** |
| Estimates/time | Possible only as unstandardized custom fields; no rollups or time ledger | Estimate systems and related planning UI | Plane gap: **medium-high** |
| Analytics/reporting | CLI lists and filters; no aggregate reporting UI | Real-time analytics, progress views and burn-downs | Plane gap: **high** |
| Knowledge/docs | Immutable, provenance-bearing generation/node/relation projection; operational authority is kept separate | Collaborative rich-text Pages with images, links, mentions, AI and conversion into work items | Different strengths: SpruceGoose integrity, Plane authoring |
| Collaboration | Assignee and label strings only | Members, roles, comments, reactions, mentions, uploads, subscriptions and notifications | Plane gap: **critical** for multi-user use |
| Identity/access | No application user, workspace, session, authorization or RBAC resources found | Workspace/project membership, roles and OAuth-capable authentication | Plane gap: **critical** before shared exposure |
| API/integrations | Operator CLI and internal transactional outbox; no public HTTP API or webhook administration | Service API surface, developer settings and webhooks | Plane gap: **high** |
| Automation runtime | Workflow definitions allow `oban`, `taskflow`, and `openclaw`, but the repository currently contains only an Oban outbox worker; task runtime transfer remains incomplete | Product automations/integrations, but not a governed agent execution authority | SpruceGoose design advantage, implementation gap: **critical** |
| Audit/evidence | Stable task IDs, arbitrary typed evidence links, SOP pinning, diagnosis-specific closure requirements | Product activity/history, without SpruceGoose's systemwide completion gate | SpruceGoose materially ahead |
| Reliability controls | Optimistic locks, advisory locks, database triggers, transactional outbox, retries/backoff and negative-path tests | Mature distributed application, but the comparison found no equivalent task-governance contract | SpruceGoose ahead in its narrow authority core |
| Immutable knowledge | Generation provenance, digest/revision idempotence, stale rejection and atomic active-generation replacement | Mutable collaborative Pages | SpruceGoose ahead for canonical machine knowledge |
| Deployment footprint | Elixir/PostgreSQL/Oban, currently CLI-only | React/Django/Node plus multiple application and deployment surfaces | SpruceGoose simpler, Plane much more complete |

## Where SpruceGoose is up to par

SpruceGoose is genuinely at parity for the narrow work-item substrate:
projects, roadmaps, workflows, tasks, priorities, due dates, assignees, labels,
custom fields, boards, columns, ranks, saved filters and inbox triage all exist.
The current CLI exposes create/read/update/delete paths for hierarchy and board
metadata and scoped task listing.

It exceeds Plane's visible product contract in these areas:

1. Every new task can be made to carry a verifiable Definition of Done and an
   exact SOP path, SHA-256 digest and acknowledgment time.
2. A closed diagnosis requires finding, regression and SOP references.
3. Tasks and subordinate TODOs have explicit DAG semantics and fail closed on
   invalid edges or unfinished predecessors.
4. Database constraints and triggers defend important invariants from callers
   that bypass the CLI.
5. State changes produce transactional outbox records with bounded retries and
   exponential backoff.
6. Knowledge generations preserve provenance and reject stale or incomplete
   replacement rather than silently mutating the active corpus.

## Where SpruceGoose lags

### P0 — blocks use as a Plane replacement

- No web or mobile product surface.
- No user/workspace identity, authentication, RBAC, membership or tenant
  boundary.
- No comments, mentions, notifications, attachments or activity feed.
- No public API/webhook administration contract.
- No implemented durable task runner despite runner kinds in workflow
  definitions. Oban currently dispatches only outbox events.

### P1 — blocks mature planning

- No cycles/sprints, burn-downs, velocity or capacity.
- No modules/milestones.
- Roadmaps have only `key` and `name`; there are no dates, outcomes, progress
  rollups or timeline presentation.
- No standardized estimates or time tracking.
- No analytics or portfolio reporting.
- Kanban is the only implemented layout; no list, calendar, spreadsheet or
  Gantt views.

### P2 — product depth and ergonomics

- No rich-text task description or collaborative page editor.
- No work-item templates, recurring work, bulk editing or import/export
  product flows.
- Saved filters are board-scoped and limited to six keys.
- Assignees and labels are strings rather than governed resources, so
  referential integrity and lifecycle management are absent.
- No end-user notification preferences, subscriptions or snooze behavior.

## Recommended boundary

Do not rebuild Plane feature-for-feature inside SpruceGoose now. Preserve
SpruceGoose as the sole governed execution authority and treat a human-facing
work tracker as a replaceable projection/client until the convergence roadmap
delivers the missing runtime.

The next SpruceGoose phases should prioritize:

1. durable Oban execution, resume/wait/retry/child-task semantics and recovery;
2. identity, authorization and approval resources;
3. a stable API/event contract with idempotent projection adapters;
4. a deliberately small operator UI for governed admission, evidence,
   approvals and recovery;
5. only then, planning features whose absence is proven to impede the actual
   workflow.

Plane should be adopted only if human collaboration needs justify the
operational cost. If adopted, it must not become a second lifecycle authority:
Plane work items should project to/from stable SpruceGoose IDs, with
SpruceGoose retaining final state, dependency, evidence, decision and approval
authority.

## Twelve-Factor review

This comparison reviewed the pinned upstream `main` baseline.

- **Codebase:** SpruceGoose is one versioned repository. Satisfied.
- **Dependencies:** Mix dependencies are explicit. Satisfied.
- **Config:** runtime/database/outbox behavior uses environment/application
  configuration; secret handling was not expanded in this audit. Partially
  evidenced.
- **Backing services:** PostgreSQL and Oban are explicit backing services.
  Satisfied for the current scope.
- **Build/release/run:** compiled escript and migrations exist, but a formal
  immutable release contract was not evidenced. Partial.
- **Processes:** CLI commands are short-lived; the dispatcher is a service
  process. Applicable and broadly aligned.
- **Port binding:** not applicable to the current CLI-only product; it becomes
  required if an HTTP surface is added.
- **Concurrency:** Oban and database locking are explicit. Satisfied in the
  tested authority core.
- **Disposability:** outbox retry/recovery behavior is tested; whole-service
  shutdown/startup evidence was not part of this audit. Partial.
- **Dev/prod parity:** dev/test migrations are exercised; production parity
  was not inspected. Deferred.
- **Logs:** database/debug and process logs exist, but structured operational
  log contracts were not inspected. Partial.
- **Admin processes:** the CLI provides one-off administrative operations.
  Satisfied.

No Twelve-Factor observation changes the comparison verdict or authorizes a
deployment change.

## Evidence and limitations

SpruceGoose evidence:

- `lib/spruce_goose/cli/command.ex`
- `lib/spruce_goose/workflows/task.ex`
- `lib/spruce_goose/workflows/lifecycle.ex`
- `lib/spruce_goose/workflows/project.ex`
- `lib/spruce_goose/workflows/roadmap.ex`
- `lib/spruce_goose/workflows/workflow.ex`
- `lib/spruce_goose/workflows/saved_filter.ex`
- `lib/spruce_goose/knowledge.ex`
- `lib/spruce_goose/outbox/dispatcher.ex`
- `priv/repo/migrations/`
- compiled CLI help for every command family
- `mix test`: 126 tests, 0 failures

Plane evidence:

- official `makeplane/plane` repository at the pinned `preview` commit
- `README.md` feature inventory
- `packages/constants/src/issue/layout.ts`
- `packages/constants/src/settings/project.ts`
- `packages/constants/src/settings/workspace.ts`
- `packages/constants/src/analytics/common.ts`
- application API, service, store and type surfaces under `apps/`

Plane's Cloud/commercial-only features were not used to mark SpruceGoose down.
The comparison is against features evidenced in the official repository.
Indexed web search was quota-blocked, so the audit deliberately relied on the
official repository rather than third-party summaries.
