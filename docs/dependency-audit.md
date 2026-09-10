# Dependency acceptance gate

Run `scripts/audit-dependencies` from the candidate checkout. The gate requires
Python 3.9+ (standard library only), Git, and **Hex 2.5.1** on the repository's
pinned Elixir/OTP toolchain. Provision Hex in the isolated runner with
`mix local.hex 2.5.1 --force`; the gate never installs or upgrades tools itself.

The supported report contract is the released
[Hex 2.5.1 audit task](https://github.com/hexpm/hex/blob/v2.5.1/lib/mix/tasks/hex.audit.ex)
and its
[advisory formatter](https://github.com/hexpm/hex/blob/v2.5.1/lib/hex/utils.ex).
That release does not support SARIF. Do not pass `--format sarif` and assume
the result is structured: its task ignores arguments. A future Hex upgrade
requires report fixtures and an explicit parser/version update.

## Pass and refusal

A clean audit requires exit zero and the exact completed clean report.
An advisory report requires exit one, an `Advisories:` section, complete
advisory records, and the final `Found packages with security advisories`
marker. Unknown output, incomplete reports, setup/network errors, unexpected
statuses, changed inputs, and unaccepted findings fail closed. Color escapes
are normalized; other unsupported controls refuse.

Retirements and Hex's ignored/policy-accepted sections refuse. They cannot
bypass this repository's owner-and-expiry policy. Advisory aliases are display
metadata; the primary ID must match the allowlist literally. A summary that is
only a URL is unsupported and refuses, because it cannot be distinguished from
a truncated record. Unexpected warnings also refuse and need investigation.

`.hex-audit-allowlist` contains one whitespace-separated record per accepted ID:

~~~text
ADVISORY_ID YYYY-MM-DD OWNER RATIONALE...
~~~

Every record must have a unique literal ID, a real calendar date, owner and
rationale. Missing/unreadable files, malformed records and expired records
refuse even if no current finding matches them. Acceptance lasts through the
specified UTC date and expires the next day; the gate rechecks after scanning.
`HEX_AUDIT_ALLOWLIST` selects a separately reviewed file when needed; unset or
empty uses the repository file. The result prints the exact lockfile and
allowlist SHA-256 values, audit date, Hex version, raw audit output and status,
and accepted/blocking IDs. Capture stdout/stderr as the gate log.

The current Decimal acceptance is unchanged: owner `lars`, expiry 2026-10-08.
This fix does not reassess its reachability or assert that no patched release
is now available. Review it separately before expiry. Do not extend its date
automatically.

The gate validates Hex's report, not the freshness of its registry cache.
Runner/network and registry freshness evidence remain part of release review.
Bare `mix hex.audit` is useful diagnostic output, but does not implement this
repository's time-bounded acceptance policy. Never add `|| true` to continue
past a failed wrapper.

## Isolated checks

Run without application boot or a database:

~~~sh
python3 test/release_gate_scripts_test.py
elixir test/test_database_config_test.exs
elixir test/release_ci_pipeline_test.exs
~~~

The Python suite uses disposable Git checkouts and a stub Mix executable. It
checks parser refusals, literal allowlist matching, command ordering, optional
environment propagation, generated database naming and failure cleanup.
The configuration suite reads test config in separate Elixir processes;
it never connects to a database. Both suites also run under `mix test` through
their ExUnit files.

The full test suite and mandatory `separate_sessions` lane still need an
independent disposable database. SCRAM correct/missing/wrong-password and
trust-auth integration results must be recorded for the actual candidate;
passing a stub test is not evidence of a successful database connection.

## Release boundary

The tracked Woodpecker lane calls `scripts/ci-governed-release`, which calls
this gate before compilation, test database creation and release assembly.
Run it only in an isolated runner. It builds an artifact and performs
artifact-only validation; it does not authorize activation.

Before release assembly, supply `SPRUCE_GOOSE_TASK` for the actual governing
task. The pipeline checks its identifier shape and forwards it to the builder;
it no longer substitutes an unrelated historical task. Identifier validation
does not prove task authorization: the runner must obtain the binding through
the existing approval process. No task is created by this script.

The external deployment agent's active runbook revision remains unverified.
Its current release instructions must resolve to the candidate's own wrapper,
with the version and policy above. Publishing this document does not establish
that the external runbook was updated. Source reconciliation, production
database checks and live service changes remain outside this prerequisite fix.
