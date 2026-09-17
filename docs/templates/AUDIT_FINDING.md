<!--
Derived from templates/records/AUDIT_FINDING.md in larsbx/agent-icm @ sha256:03f8cdcf41e62f98
Edit the canonical template or estate.toml, then re-render: make estate
Hand-edits here are drift and `make estate-check` fails on them.
-->

# Audit — `<scope>`

<!--
State up front what could and could not be executed. An audit from reading is
an audit from reading; it is useful, and it is not a passing suite.
-->

- **Scope:** `<the commits, files or behaviour audited>`
- **Revision:** `<sha>`
- **Method:** executed suite | static read | AST/format check | hand-trace | `<mixed — say which, per finding>`
- **Not established:** `<what this method cannot show; environment limits, blocked toolchains, unrun gates>`

## Findings

### N. `<finding, as a claim>`

- **Severity:** blocking | should-fix | note (not a bug)
- **Established by:** `<run output, the lines read, the trace>`
- **Failure scenario:** `<concrete inputs or state -> wrong output, crash, or wrong claim>`
- **Disposition:** resolved in `<sha>` | open | accepted with rationale

<!-- The explanation. Mechanism, not adjectives. -->

## Resolved

<!-- Findings closed by this same change, each with the fix and why it is the right one. -->

## Note (not a bug)

<!--
Things worth knowing that are not defects. Keep them separate from findings, so
the count of real defects stays honest.
-->
