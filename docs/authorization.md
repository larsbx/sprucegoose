# Authorization

Status: **implemented.** Actors, scoped grants, and `Ash.Policy.Authorizer`
policies across the `SpruceGoose.Workflows` domain.

## What this is, and is not

Every agent on this host — OpenClaw, Pi, Claude Code, Codex — runs as the same
unix user. `SO_PEERCRED` on the CLI socket returns the same uid for all of them.
So `--as openclaw` is a **declaration, not a credential**, and nothing in this
system can tell a caller that lies about its own name.

This is the same class of control as `vault-write-authorization.py`: it makes
ungoverned and out-of-scope action fail loudly by default, and binds every
mutation to a named actor. It withholds no secret, and a determined local
process bypasses it by writing rows directly.

The MCP surface is different. There the caller presented a valid OAuth bearer
token before `SpruceGoose.Web.ActorPlug` ran, so that side is genuinely
authenticated.

Resolution therefore sits behind a behaviour, `SpruceGoose.Actors.Resolver`,
with one `Declared` adapter today — the same shape `SpruceGoose.Identity` uses
and for the same reason. Two adapters would move the boundary for real, and
neither touches a policy:

- a **token-bound** adapter, resolving a per-actor secret through the
  `AshAuthentication` token store this app already runs;
- a **peer-credential** adapter, once agents run as distinct unix users, reading
  the uid the kernel attaches to the socket, which cannot be forged.

## Model

`SpruceGoose.Actors.Actor` — `name`, `kind` (`:human | :agent | :system`),
`description`, `disabled_at`.

`SpruceGoose.Actors.Grant` — one role, over one scope, for one actor, with
`granted_by` and `granted_at`. A separate resource rather than an array column
on the actor, because the questions actually asked of a permission are "who
granted this, and when" and "revoke exactly this one".

`kind` is not cosmetic. It is the discriminator the self-approval rule turns on.

### Roles

| role | grants |
|---|---|
| `reader` | read within scope |
| `operator` | task lifecycle, board moves, metadata, todos, dependencies, inbox triage |
| `artifact_verifier` | verify and record artifact-custody receipts |
| `proposer` | propose and withdraw revisions |
| `approver` | approve revisions, and the entity `:revise` actions they apply through |
| `author` | create and remove project, roadmap, workflow, board, column, filter; `rename` |
| `admin` | manage the actor registry itself |

Roles do not imply one another, with one exception: **every grant implies
`reader` within its own scope.** An operator that cannot read the task it is
operating on is not a coherent grant.

`admin` is registry authority, not superuser. An admin holding nothing else can
grant roles and create actors, and cannot touch a single task — though it can of
course grant itself anything, which is why Genesis hands out the complete seven-role
set—seven global grants—rather than making the first operator run six more commands
for no safety gain. The disposable recovery rehearsal later adds one separate
`operator` grant for `recovery-agent`, so its expected database inventory is eight
grant rows in total; that is not an eighth Genesis role.

### Scopes

`*` (fleet-wide) or `project:KEY`. Two levels only: deeper scoping turns every
permission check into a tree walk, and work on this fleet is partitioned by
project. A grant naming a project that does not exist is refused at grant time —
a permission nobody can use is one nobody will notice is wrong.

A record's scope is its owning project, resolved by SQL walk up to `projects`
(`SpruceGoose.Actors.Scope`). The walk rather than a preloaded relationship
graph, because the check runs inside a policy where the record is loaded but its
ancestors are not.

Two things resolve to **global** scope and so need a `*` grant:

- **Creating a project.** It cannot be scoped to itself before it exists.
- **The inbox.** Captures arrive before triage, so they belong to no project yet.

Ledger parity and recovery import are a narrower exception. Both require
`admin` at global scope because they read fleet-wide historical state through
raw SQL. The check runs before path inspection, file access, or parity queries,
so an unauthorized caller cannot use the response as a file-existence oracle.
A project-scoped role is not sufficient.

## Enforcement

Policies live on the resources, so every surface inherits them — the CLI, the
read-only MCP tools, and anything added later.

```elixir
policy action_type(:read) do
  authorize_if(Readable)          # filters to the actor's projects
end

policy action([:propose, :withdraw]) do
  authorize_if(HasRole.proposer())
end

policy action(:approve) do
  authorize_if(HasRole.approver())
end
```

`SpruceGoose.Checks.HasRole` is a `SimpleCheck` for mutations.
`SpruceGoose.Checks.Readable` is a `FilterCheck`, so a `project:alpha` reader
running `task list` gets alpha's tasks rather than an authorization error —
refusing would make every list command depend on the caller already knowing its
own scope.

An actor with **zero** grants is refused outright rather than shown an empty
page: Ash collapses a constant-false filter into `Ash.Error.Forbidden`, and
"you hold no grants" is actionable where an empty list reads as "no such data
exists". `SpruceGoose.Actors.Refusal` turns that error into a sentence naming
the missing grant and the command that fixes it.

### `authorize :when_requested`

The domain sets `authorize :when_requested`, not Ash's default `:by_default`.

Every CLI call therefore goes through `SpruceGoose.Authz`, which sets `actor:`
and `authorize?: true` unconditionally. `test/authz_lint_test.exs` fails the
build if a CLI module calls `Ash.create`, `Ash.update`, `Ash.destroy` or
`Ash.read` directly. The safety comes from the funnel being mandatory rather
than from the framework default, and that test is what makes it mandatory.

The trade is deliberate: `:by_default` would have required rewriting 142 direct
`Ash.*` call sites in the suite to opt out — a larger and noisier change than
the guarantee was worth, since the CLI is the only write surface.

The actor is **request-scoped**, not an argument. `Executor.run/2` establishes it
once with `Authz.with_actor/2`, and `Authz.actor!/0` raises if a call is made
outside that scope. Threading an actor through sixty command clauses and twenty
private helpers gives twenty more chances to drop it, and dropping it is silent.
An implicit dependency that cannot fail quietly beats an explicit one that can.
The scope is the calling process, and `SocketPlug` runs each request in its own
supervised task, so requests cannot see each other's actor.

## Naming the actor

Precedence: `--as NAME`, then `SPRUCE_GOOSE_ACTOR`, then the `:default_actor`
application setting.

Both fallbacks are unset by default, so a deployment configuring neither refuses
every request that does not name its actor. The environment variable is read
**service-side** — it describes the environment the CLI service was started in,
not the caller's shell — so `--as` is the real mechanism and the rest is a
convenience for a single-agent deployment.

`--as` is stripped from the argument list before parsing, because each verb
parses with `strict:` and a flag not declared on that specific verb would
otherwise be an error rather than a global option.

## Genesis

The registry gate is `admin` at global scope, with one exception. While the
`actors` table is **empty** there is no admin to authorize the first one, so
`actor add` is permitted and must create a `:human` holding every role at `*`.
The response says so loudly. Once one actor exists, genesis is closed.

The empty-registry decision, first actor, and complete seven-grant Genesis set execute
in one PostgreSQL transaction under the same transaction-scoped advisory lock used by
every actor/grant mutation. Concurrent first requests therefore serialize: exactly one
can become Genesis, while every other request observes the now-nonempty registry and
enters the ordinary admin gate. For non-Genesis writes, the acting administrator is
re-read and re-authorized only after acquiring that lock, so disable or grant revocation
cannot invalidate authority between the check and commit. Any actor or grant failure
rolls the whole transaction back, and Ash notifications are delivered only after commit.

A control that can lock you out of fixing it is not a control, it is a trap.
The same reasoning keeps vault reads ungated.

Two further refusals guard the registry from becoming unmanageable: the last
global `admin` grant cannot be revoked, and an admin cannot disable itself.

Registry reads run with `authorize?: false` throughout. The registry is what
every policy check reads; subjecting it to those policies would make
authorization depend on being authorized.

## CLI

```
actor add NAME --kind human|agent [--description TEXT]
actor list [--kind human|agent|system]
actor show NAME
actor disable NAME REASON
actor enable NAME

grant add NAME --role ROLE --scope '*'|project:KEY
grant list [--actor NAME] [--role ROLE]
grant remove NAME --role ROLE --scope SCOPE

whoami
```

`whoami` is deliberately ungated: an actor may always see its own name and
grants. Any other rule makes "why was I refused?" unanswerable from the CLI.

Bootstrapping a fresh store:

```sh
sprucegoose actor add lars --kind human --description operator
sprucegoose actor add openclaw --kind agent --as lars
sprucegoose grant add openclaw --role operator --scope project:openclaw-system --as lars
sprucegoose grant add openclaw --role proposer --scope project:openclaw-system --as lars
sprucegoose whoami --as openclaw
```

That agent can now drive tasks and propose revisions in one project, and can
neither approve anything nor see any other project.

## MCP

`RequireScopePlug` runs after `BearerPlug` and rejects a token that does not
carry the exact `mcp` delegated scope. `SpruceGoose.Web.ActorPlug` then reads
only the verified token claim `client_id`, resolves it through the
administrator-governed client-ID to actor-ID binding, and calls
`Ash.PlugHelpers.set_actor/2`. Registration metadata such as `client_name`,
caller-controlled connection assignments, and the OAuth user identity are not
actor authority inputs. AshAi reads the actor from the connection, so the
read-only tools inherit the same project scoping with no change to the tool
list. An unbound client is refused, not defaulted.

Note that `AshAi.exposed_tools/1` ends in a `can?` filter, so an actor-less
caller now sees an empty tool list. That is the surface the plug exists to keep
anyone from reaching.

## Related

- `docs/revisions.md` — the governed revise verb these roles gate.
- `docs/sop-versioning.md` — the other gate a task must pass, and why a patch
  bump to the SOP no longer re-acknowledges the fleet.
- `lib/spruce_goose/actors/resolver.ex` — the boundary, stated in full.
