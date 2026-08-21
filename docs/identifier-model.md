# Identifier Model

Status: **implemented for originated and derived identifiers.** The original
diagnosis was `tsk-20260729T130158Z-4fabcd8e`. Golden vectors and BLAKE3
known-answer tests protect the encoding and derivation contract. Class I
upstream-imported identifiers remain deliberately excluded as described below.

## Principle

Identity is *who authored which operation*, not *what the bytes were*.

- **ID** ← the dot `(peer_id, origin_seq)`
- **Payload integrity** ← a separate `payload_b3` column

The body must not appear in the ID tuple. If `(peer_id, origin_seq)` is unique
per peer-operation, the body contributes nothing to uniqueness and actively
breaks idempotence: a corrected retry of the same logical event (typo fix
before propagation, re-serialisation, field reordering) would mint a different
ID and duplicate the record.

This also dissolves the P1.1 collapse (`sha256(body)` made two distinct
captures with identical text share an ID). Distinct dots yield distinct IDs by
construction rather than by luck of the hash input.

## Encoding

Length-prefixed to remove delimiter ambiguity (`a:b` must not equal `a` + `:b`):

```
enc(f)          = u32be(byte_size(f)) || f
H(ns, f1..fn)   = blake3(enc(ns) || enc(f1) || ... || enc(fn))
```

BLAKE3 rather than SHA-256, for one hash function across the system.

## uuid_v7d: deterministic, time-ordered, convergent

The v7-versus-hash tension is false. It only exists if the digest is allowed to
occupy all 128 bits. Restrict it to the free bits and the timestamp prefix
survives.

```
uuid_v7d(ts_ms int8, d bytea) -> uuid
  [  0.. 47]  ts_ms          convergent: origin's stamp, carried, never re-read
  [ 48.. 51]  0x7            version
  [ 52.. 63]  d[0..1]        12 bits of digest
  [ 64.. 65]  0b10           variant
  [ 66..127]  d[2..9]        62 bits of digest
```

74 bits of digest. Time-ordered, deterministic, convergent.

`ts_ms` must come from a **convergent clock reading**: the originator's wall
clock, stamped once and carried with the event. Never re-read at the receiving
peer, or two peers derive different IDs for one event.

RFC 9562 leaves `rand_a`/`rand_b` implementation-defined, so this is
conformant. Note it in the function comment regardless: a "v7 whose tail is not
random" will surprise the next reader. Uses the same nibble-setting technique
as the existing `uuid_generate_v7()`.

## Classes

### Class O — originated

Exactly one author: task creation, todo, board, saved filter.

```
ts = origin_wall_ms                              stamped at origin, immutable
d  = H(NS_<entity>, peer_id, u64be(origin_seq))
```

### Class D — derived

Deterministic function of an already-convergent parent: outbox events,
revisions, dependency edges.

```
ts = parent.origin_wall_ms                       inherited; keeps children
                                                 index-adjacent to parent
d  = H(NS_<entity>, parent_id, <discriminators>)
```

Outbox specifically:

```
d  = H(NS_OUTBOX, task_id, u64be(revision), u32be(n))
ts = inherited from the task revision
```

### Class I — upstream-imported (documented exclusion)

Two peers independently importing the same upstream object share no origin dot,
so Class I is neither O nor D. It would need:

```
ts = upstream.created_at
d  = H(NS_<entity>, source_system, source_id)
```

**Eligibility rule:** a source that does not expose a stable creation timestamp
is not eligible for derived IDs at all.

**Not implemented, because no live Class I source exists:**

- 134 `workflow_tasks` carry `legacy_source = "tuxedo"`, but provenance is only
  `legacy_source` / `legacy_raw` / `legacy_encoded_dod`. No stable upstream id,
  no upstream `created_at`. They fail the eligibility rule.
- `projects` and `roadmaps` have no provenance columns at all.
- Authority is `mode=ash`, `cutover_at=2026-07-27`, ledger import fail-closed
  per PC-01, so no new Class I rows can arrive.

Historical imports keep their existing v4 IDs as grandfathered rows and are
never re-derived. A real upstream sync (GitLab, Notion) requires reopening this
as a governed decision at that time.

## origin_seq

Per-peer strictly-monotone counter, never reused across restarts. **This is the
only genuinely new durable state, and the only part that can silently go
wrong:** a counter reset mints colliding IDs for distinct events.

It needs the same durability guarantee as the log itself. If a replication
substrate already provides a monotone `seq`, use that and add nothing.

**Current repo state:** no Hypercore/Autobase/Corestore substrate exists here,
so `origin_seq` cannot borrow one. It is new state requiring its own durability
design.

## event_key

Currently `task:<task_id>:<revision>:<n>`, with the outbox trigger deduping
`ON CONFLICT (event_key)`. It embeds the natural key directly, so changing ID
derivation silently changes 748 rows of dedup meaning.

Make that frontal rather than emergent:

1. `event_key` becomes a **projection** of the Class D tuple, not an
   independent construction.
2. Keep the text form for human legibility and the existing `ON CONFLICT` path.
3. Add `event_id uuid` derived from the same tuple; move the unique constraint
   there.
4. The text key can then change format later without touching dedup semantics.
5. Backfill the 748 existing rows under the new derivation **in the same
   migration that swaps defaults**, with a golden-vector test.

## TaskId

`TaskId.generate/2` currently appends 4 bytes of fresh entropy, so it diverges
across peers even with the clock pinned to an identical instant.

Its suffix becomes the first 8 hex of `d`. Then `tsk-<ts>-<hex8>` and the uuid
are two encodings of one identity, not two identities.

## Preconditions for remediation

- `blake3` is **not** a dependency today.
- No `peer_id` notion exists anywhere in the codebase.
- No replication substrate exists to source `origin_seq` from.
- `uuid_generate_v7()` **does** already exist (migration `20260705142134`),
  verified time-ordered; it is unused, and every table still defaults to
  `gen_random_uuid()` (v4).
- Blast radius is ~1100 rows across 14 FK constraints; the Kanban tables are
  still empty. This is the cheapest the change will ever be.
