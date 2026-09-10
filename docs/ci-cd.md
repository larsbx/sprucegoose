# CI, artifact delivery, and hooks

Forgejo is the canonical source, review, and merge authority. Woodpecker is the
canonical CI/build plane; deployment acceptance and authorization belong in
SpruceGoose. See [deployment integration](deployment-domain.md) for the evidence
contract, reconciliation prerequisites, and adapter acceptance gates.

The GitHub mirror checks every pull request and main push. Its workflows use disposable
GitHub-hosted Ubuntu 24.04 runners, the versions in `.tool-versions`, and Hex
2.5.1. PostgreSQL 16 service containers hold only test data. No deployment
credentials, production database, authority signer, or service socket is needed.

| Trigger | Work | Result |
| --- | --- | --- |
| PR opened, updated, or reopened; push to main | Fast script/hook regressions; SCRAM and trust database matrix; audit, formatter, compile, migrations, full suite, separate-session suite | GitHub check results and 14-day evidence artifacts |
| Daily at 07:23 UTC; manual Dependency audit run | Current dependency advisory report and acceptance expiry | Failing run on unaccepted/expired findings or audit errors; 14-day log |
| Manual Artifact delivery run on main, with an existing task ID | Repeat the checks on the selected commit; build, inspect, and validate a release archive | Archive and receipt retained for 30 days, with separate build evidence |
| Local pre-commit | Check staged whitespace, including partially staged files | Reject malformed staged changes |
| Local pre-push | Run the shared fast checks against the working checkout | Reject failed script regressions or shell syntax |

The existing Woodpecker push configuration remains in place. Its local backend
still needs a provisioned toolchain, disposable database, and a supplied governing
task ID. These GitHub workflows add verification and artifact delivery; they do
not change Forgejo's declared source authority or synchronize the two repositories.

## Local hooks

Run once per clone:

```sh
scripts/install-git-hooks
```

This sets local `core.hooksPath` to `.githooks`. Existing custom hook paths or
pre-commit/pre-push files are preserved; integrate the tracked hook commands with
them if present. Hooks are developer feedback, not a substitute for CI: pre-push
checks the current checkout, which can differ from the commits being pushed.
The fast checks need Python 3.9+, Git, and Bash, and use fake Mix/database commands.

```sh
scripts/check-local
```

## Shared full check

In a clean checkout with the specified toolchain and an independent disposable
PostgreSQL instance, set the `SPRUCE_GOOSE_TEST_DATABASE_*` connection variables and
a numeric `CI_PIPELINE_NUMBER`, then run:

```sh
scripts/ci-governed-release --check
```

The script owns the database name `spruce_goose_ci_<pipeline number>` and drops it
on success or test failure. Use distinct pipeline numbers for concurrent runs
sharing a test server. GitHub's two authentication jobs have separate database
containers. Trust jobs explicitly unset the password; SCRAM jobs use an ephemeral
test password. CI also runs the standalone configuration regressions without
starting the application.

The check mode stops after both suites, cleanup, and workspace verification; it
does not need a build task. `--release` (also the legacy no-argument default)
continues through the existing governed builder and artifact-only validator.
Unknown arguments refuse before any Mix command. The release script retains its
existing provenance and receipt requirements.

## Artifact delivery

Use Actions → Artifact delivery → Run workflow, select `main`, and supply the
existing governing `tsk-YYYYMMDDTHHMMSSZ-xxxxxxxx` task ID. The workflow records the
exact event commit, run ID, and attempt in the build provenance. A task ID's syntax
is checked, but this does not attest its existence or grant deployment authority.
An authorized orchestration client can invoke the same `workflow_dispatch` event
with `ref: main` and `inputs.task_id`; no separate custom webhook server is needed.

The candidate archive is uploaded only after all build and validation steps
succeed. Check/build logs and evidence are retained on failure as well; crash
dumps are excluded from uploaded artifacts. Workflow cancellation can interrupt
shell cleanup, but GitHub tears down the job's disposable service container.
No workflow calls the activation script, applies production migrations, updates
the live symlink, or restarts a service. An uploaded archive is not a deployment.

For the deployment hook, consume verified canonical Woodpecker evidence bound
to the Forgejo repository, reviewed ref, commit/tree, pipeline run/attempt,
configuration digest, typed artifact digest, and receipt. GitHub Artifact delivery
is optional mirror evidence and does not substitute for canonical acceptance.
Reconcile the canonical source first; activation needs a separate SpruceGoose
authorization and the host-adapter recovery gates. A PR event or an artifact name
cannot authorize activation. These workflows create no deployment endpoint,
credential, repository webhook, or host-side service.

## Enabling and observing automation

After canonical merge, inspect the exact candidate's Woodpecker gates and mirror
the accepted source downstream. Inspect Forgejo branch protection and canonical
runner isolation separately; GitHub settings do not enforce either. On the
GitHub mirror, confirm Actions is enabled and inspect its main run. Expected
CI checks are `Fast checks`, `Tests (scram-sha-256)`, and `Tests (trust)`. Once these
run successfully, make those checks required in the repository's main ruleset if
merges must be gated. Workflow files alone do not enforce branch protection.
Repository administration settings were not changed by this patch.

Daily schedules become active on the default branch and may run later than the
nominal time. Failures appear in Actions and use the account's existing GitHub
notification settings; no external messaging integration is installed.

References: [setup-beam version files](https://github.com/erlef/setup-beam),
[GitHub PostgreSQL services](https://docs.github.com/en/actions/use-cases-and-examples/using-containerized-services/creating-postgresql-service-containers),
[artifact retention and upload behavior](https://github.com/actions/upload-artifact).

## Validation of this change

The local Python regressions exercise successful check-only runs, both test
invocations, failed tests and cleanup, rejected unknown modes, staged whitespace,
hook installation conflicts, and pre-push failure propagation. Existing audit
regressions remain in the same fast check command. End-to-end Elixir, PostgreSQL,
formatter, and release results must come from the real CI jobs; local fixture
passes do not claim those results.
