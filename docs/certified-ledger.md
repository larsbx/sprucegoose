# Certified ledger: canonical form, export, and re-rooting

## Canonical form

Every certified event's identity is SHA-256 over canonical bytes of the
object `{event_type, idempotency_key, payload, roots, stream}`. Since
2026-10-20 those bytes are **RFC 8785 JSON Canonicalization Scheme** (`jcs-v1`)
restricted to the types the ledger carries: objects with string keys, arrays,
strings, integers within ±(2^53 − 1), booleans, and null. Keys sort by UTF-16
code units; strings escape exactly as ECMAScript `JSON.stringify`; floats are
refused. `SpruceGoose.Kernel.Canonical` implements it and
`test/canonical_form_test.exs` pins the conformance vectors.

Events written before the adoption are in the legacy form (`etf-v1`): a
version prefix plus Erlang External Term Format with `minor_version: 2`. The
`canonical_form` column on `certified_events` names each row's form; legacy
rows were labelled by the column default without being touched, and the
legacy encoder is kept so every one of them still re-derives.

## Re-rooting record

`sprucegoose ledger rekey` (admin, global scope) runs once. For every
`etf-v1` event it computes the `jcs-v1` identity of the same content and
records the pair in `certified_event_rekeys`, an immutable table with a
foreign key to the event's original identity. It then appends one
`CanonicalFormAdopted` event on `authority:kernel` naming the record's
content identity and the number of events rekeyed. No existing row changes.
`EventLedger.verify/2` honours either identity of a rekeyed event: the stored
bytes must still hash to the original, and the content re-encoded as JCS
must hash to the new one.

## Export

`sprucegoose ledger export PATH` (admin, global scope) writes the whole
ledger in global sequence order as JSON Lines, schema
`sprucegoose-certified-ledger-export-v1`: a header line, then one object per
event with `sequence`, `stream`, `stream_position`, `event_type`,
`idempotency_key`, `payload`, `roots`, `canonical_form`, `identity`, and
`jcs_identity` (the identity itself for `jcs-v1` events, the rekeyed identity
for legacy ones once the record exists). The path must be absolute and must
not exist; the file is written owner-only.

`scripts/verify-certified-ledger.py EXPORT.jsonl` recomputes every `jcs-v1`
identity with Python's standard library and checks that every stream's
positions are contiguous from 1. It needs no BEAM, no database, and no
SpruceGoose code. Exit 0 means every checked identity and every stream order
held; legacy events are counted, not recomputed.

## Invariants in two places

`test/invariant_parity_test.exs` asserts that every table protected by an
immutability or identity trigger is owned by a resource exposing no action
that could violate it, that frozen identity columns are accepted by no
update action, and that port-owned immutable tables have no update or delete
in their contract. PostgreSQL is the second enforcer of those invariants, not
the only one, and the test is what keeps that true as resources change.

## Locks

Transaction-scoped mutual exclusion goes through `SpruceGoose.Kernel.Locks`.
The PostgreSQL adapter uses advisory locks; the in-memory adapter serialises
within one node. Callers name what they serialise, never how.
