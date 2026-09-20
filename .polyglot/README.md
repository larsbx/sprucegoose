# Polyglot migration scaffold

**Status:** migration scaffold; non-normative and non-executable  
**Branch:** `polyglot/migration-v1`

## Repository allocation

- **Repository:** `larsbx/sprucegoose`
- **Primary language authority:** Elixir/Ash
- **Supporting languages:** Haskell, Rust, TypeScript, SQL
- **Assigned responsibility:** Authoritative deployment domain

## Authority rules

1. Existing production, proof, certificate, governance, and deployment authority remains unchanged until a separately reviewed migration slice explicitly changes it.
2. Every invariant has exactly one canonical implementation. Secondary implementations are generated adapters, reference models, research oracles, conformance checkers, or formally related implementations.
3. Cross-language disagreement fails closed. No adapter may silently repair, reinterpret, or weaken a verdict.
4. A computation is not a machine-checked theorem. Only the designated proof layer may claim that status.
5. Research-oracle output is evidence or a witness proposal; it is never an acceptance verdict.
6. Forgejo remains canonical source and merge authority, Woodpecker remains canonical CI, and GitHub remains a review mirror where those estate rules apply.

## Intended source layout

The following paths are reserved. They are not created until a buildable slice needs them:

- `kernel/` — canonical executable validation, only when this repository owns it.
- `proof/` — theorem packages and proof-to-implementation refinement.
- `reference/` — pure executable semantics and golden-vector generators.
- `runtime/` — operational services and effect execution.
- `native/` — hardened native, cryptographic, host, or device boundaries.
- `adapters/` — generated or mechanically constrained interoperability code.
- `oracles/` — explicitly non-authoritative Julia/Python/research implementations.
- `schemas/` — versioned wire forms and canonical serialization contracts.
- `conformance/` — accepted, rejected, malformed, boundary, and cross-version vectors.

Only applicable paths should be introduced. Empty language silos are prohibited.

## First buildable migration slice

A follow-up PR must:

1. choose one concrete cross-language boundary;
2. name the canonical producer and consumer;
3. define a versioned schema and normalization rules;
4. include accepted and rejected golden vectors;
5. identify overflow, malformed-input, and unknown-field behavior;
6. add CI without displacing existing authoritative gates;
7. document rollback and compatibility behavior; and
8. prove that no current fail-closed boundary becomes permissive.

## Explicitly deferred

This scaffold does not:

- add language toolchains or dependencies;
- move or rewrite existing source;
- change build, test, release, deployment, or authorization behavior;
- promote Haskell reference semantics to proof authority;
- promote Julia or Python to trusted-kernel status;
- treat Mojo execution as proof beyond its declared finite checker boundary;
- change Forgejo/Woodpecker/SpruceGoose authority; or
- resolve open mathematical, governance, or product claims.

## Review gate

Before merging a buildable polyglot slice, reviewers must be able to answer:

- What unique capability justifies the added language?
- Which implementation is authoritative?
- How is semantic drift detected?
- What artifact crosses the boundary?
- How does the receiver fail closed?
- Can the new component be removed without corrupting canonical state?
