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

### Decimal correction (2026-10-19)

The lockfile selects Decimal **3.1.2**, the smallest patched release after
3.1.1. All nine
locked consumers (Ash, Ecto, Ecto SQL, Jason, JSV, OpenApiSpex, Postgrex, Xema
and Zoi) admit it through their `~> 3.0` alternatives; Decimal remains
transitive, with no direct dependency or override added.

The expired `EEF-CVE-2026-32686` acceptance is removed, not renewed. The
[current EEF record](https://cna.erlef.org/cves/CVE-2026-32686.html) identifies
versions below 3.0.0 as affected, so its claim that 3.1.1 had no fix was stale.
A separate advisory,
[CVE-2026-97853](https://cna.erlef.org/cves/CVE-2026-97853.html), affects
`Decimal.round/3` before 3.1.2. Upgrading addresses that allocation issue as
well as removing the obsolete acceptance that stopped CI before tests.

The [upstream changelog](https://hex.pm/packages/decimal/3.1.2/changelog)
reports unchanged rounding results and flags for previously successful calls.
Extreme `places` arguments now complete with bounded coefficient padding;
zero-coefficient integer/float conversions avoid exponent-sized work. These
are the intended compatibility changes. Version 3.2.0 includes additional
behavior changes and is unnecessary for this correction.

The lock entry is regenerated with Mix, selecting 3.1.2 temporarily during
resolution and restoring the original manifest afterward. Its inner checksum
is also verified against the Hex package payload, and its outer checksum
against the Hex release API. The unchanged full CI
gate must still verify dependency resolution, the complete current advisory
report, formatting, warnings-as-errors compilation, migrations, the full
suite and separate-session tests under both SCRAM and trust authentication.
Removing this entry introduces no new acceptance; other findings still fail
closed. See the correction PR's CI evidence for the exact tested commit.

### Additional blockers exposed by the complete audit

The Decimal-only candidate resolves, but the full Hex 2.5.1 audit still refuses
three advisories in the previously locked Ash and Bandit releases. Restoring
the CI baseline therefore also requires these smallest fixed versions:

| Dependency | Previous | Selected | Reason |
| --- | --- | --- | --- |
| Ash | 3.34.4 | 3.34.6 | [CVE-2026-101028](https://cna.erlef.org/cves/CVE-2026-101028.html): related-resource policies in aggregate filters/sorts |
| Bandit | 1.12.5 | 1.13.0 | [CVE-2026-105659](https://cna.erlef.org/cves/CVE-2026-105659.html) and [CVE-2026-105660](https://cna.erlef.org/cves/CVE-2026-105660.html): HTTP/2 blocked-send deadlines and HTTP/1 target authority validation |
| Thousand Island | 1.5.0 | 1.6.0 | Required by Bandit 1.13.0 |

The existing `~> 3.0` Ash and `~> 1.12` Bandit requirements admit these releases.
Targeted `mix deps.unlock` plus `mix deps.get`, with temporary exact selection
constraints, keeps the other lock entries unchanged, including Decimal 3.1.2.
The committed `mix.exs`, application code, configuration and audit policy are
unchanged; the allowlist has no active exceptions.

Compatibility review: Ash now applies related-resource read policies to
count/exists/aggregate filter and sort references, so previously unauthorized
inferences may return different results. Its intervening patch also corrects
notification shapes, temporal input validation and embedded-resource equality.
Bandit 1.13.0 intentionally tightens HTTP request validation, bounds stalled
HTTP/2 sends, reports CONNECT ports as integers, silently closes idle
connections and corrects HTTP/WebSocket framing. It adds opt-in chunked-response
compression, which this application does not enable. Thousand Island supplies
accept-time peer information required by Bandit. These transport and policy
corrections are broader than the Decimal patch and require the complete CI
matrix, including the existing Unix-socket service tests; passing dependency
resolution alone does not establish application compatibility.


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
