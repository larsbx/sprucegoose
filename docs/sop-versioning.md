# SOP versioning

Status: **implemented in SpruceGoose; the SOP document itself is not yet
versioned.** Until `Systemwide SOP.md` declares a version, every task takes the
grandfathered branch and behaviour is exactly what it was before.

## The problem

A task records which SOP it was admitted under as an opaque SHA-256. So **any**
byte change invalidated every acknowledgment on the fleet: fixing one typo forced
every in-progress task to re-acknowledge before it could complete or authorize a
vault write. That made the document governing everything else the most expensive
one to correct, which is the wrong incentive.

The vault also carries no git tags, so "which SOP was this task admitted under"
had no answer short of digest archaeology.

## The declaration

```yaml
---
sop_id: systemwide-sop
version: 1.0.0
---
```

In the file, so the version travels with the bytes that get digested and cannot
disagree with what was acknowledged. Parsing is deliberately **not** a YAML
parser: this block is a governed control surface, so it accepts exactly two keys
in exactly one shape and refuses anything else rather than interpreting it
generously.

`sop_id` was previously hardcoded in `SopGate` and assumed. Declaring it means a
configured path pointing at some other document is caught rather than trusted.

## The rule

| SOP declares a version | task holds one | outcome |
|---|---|---|
| no | no | digest must match exactly — the original behaviour |
| no | yes | refused: the SOP lost a version it had |
| yes | no | grandfathered — valid while the SOP is still at the baseline |
| yes | yes | valid while `MAJOR.MINOR` is unchanged |

A rollback to a **lower** version is refused in every case. The check runs before
the equality test, because `2.4.0 → 2.3.0` would otherwise pass as "same minor
line" and silently re-validate acknowledgments of a newer SOP.

So: a **patch** bump asserts no rule changed and costs nothing. A **minor** or
**major** bump invalidates every acknowledgment, exactly as any change did
before.

### Grandfathering

Acknowledgments predating versioning carry `sop_version: nil`. They are treated
as having read `:sop_grandfather_version` (default `1.0.0`).

This is the whole migration. Without it, adding the frontmatter block would
change the digest and invalidate every task in flight — making the introduction
of versioning the exact flag day versioning exists to prevent. `nil` therefore
stays representable in the column rather than being backfilled with a version
nobody actually read.

## The honest trade

This **loosens a fail-closed control**, deliberately.

A patch bump now carries authority: it asserts "no rule changed here", and
nothing but discipline enforces that. The digest still records the bytes each
task actually read, so a dishonest patch bump is *discoverable after the fact* —
it is not *prevented*. A reviewer comparing a task's `sop_digest` against the
document's history can always see precisely what was acknowledged.

That is the price of being able to fix a typo without re-acknowledging the fleet,
and it is worth stating in the SOP itself rather than only here.

## Two gates, one rule

`scripts/vault-write-authorization.py` in the openclaw-system vault
re-implements this check independently, for the git pre-commit write gate. It
must apply the same table, or a task SpruceGoose considers valid is refused at
`git commit`. `task show` exposes `sop_version` for exactly that reason.

Keeping one rule in two languages is a standing hazard. The mitigation is that
both sides are tested against the same table — `test/sop_version_test.exs` here,
`scripts/test-vault-write-gate.py` there.

## Rolling it out

Order matters, and getting it wrong causes the flag day this design avoids.

1. **Deploy this release to the authority host first.** A `SopGate` that
   understands only digests will treat the new frontmatter as a stale
   acknowledgment and invalidate every in-progress task the moment the document
   changes.
2. **Then version the document** — under a `VAULT_WRITE_TASK_ID`, since the vault
   refuses ungoverned writes.
3. **Then place the same bytes on every host that runs a gate.** The vault has no
   git remote, so the copies do not converge on their own. A host whose SOP
   differs is enforcing a different document.

## Related

- `lib/spruce_goose/sop_gate.ex` — the rule, in full.
- `docs/authorization.md` — the actor model the same gate sits inside.
