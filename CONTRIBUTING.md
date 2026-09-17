<!--
Derived from templates/docs/CONTRIBUTING.md in larsbx/agent-icm @ sha256:88bf9172c22bc8da
Edit the canonical template or estate.toml, then re-render: make estate
Hand-edits here are drift and `make estate-check` fails on them.
-->

# Contributing to sprucegoose

The estate's task authority and governed-release control plane.

**Language / toolchain:** Elixir 1.19, escript plus an OTP release
**CI:** GitHub Actions: `ci.yml` (fast checks, then tests under scram-sha-256 and trust), `delivery.yml`, `dependency-audit.yml`; Woodpecker via `.woodpecker.yml`

Read these first — they are normative, not background:

- `README.md`
- `docs/`
- `.sprucegoose/project.yaml`

---

## The gates

Run these before you open a pull request. Paste what they said into the PR's
evidence table.

1. fast checks, as the hooks and CI run them —

   ```sh
   scripts/check-local
   ```

2. the governed-release gate: audit, format, compile, migrate, suite, separate
   sessions —

   ```sh
   scripts/ci-governed-release --check
   ```

3. dependency audit against `.hex-audit-allowlist` —

   ```sh
   scripts/audit-dependencies
   ```

A check you did not run is not evidence. Say which ones you skipped and why;
the pull request template has a place for exactly that.

## What counts as evidence here

- CI preserves `ci-evidence/` as an artifact. The evidence is the claim; a
  green tick without it is unverified.
- Work is defined by `definition_of_done` in `.sprucegoose/project.yaml` — a
  checkable condition, not a description of effort.
- Delivery is gated on a well-formed task id
  (`tsk-YYYYMMDDTHHMMSSZ-xxxxxxxx`).
- Third-party actions are pinned by commit SHA, not by tag.

## Standing prohibitions

- Never bypass the governed release path to ship an artifact.
- Never grant the signer deployment authority. Artifact custody and signing
  stay isolated from derivation executors.
- Never pin a GitHub Action by floating tag.
- Never widen `.hex-audit-allowlist` without saying in the PR what was
  audited.

These are not style preferences. Each one is settled somewhere in the documents
above; changing one is a decision record, not a pull request comment.

## Working shape

1. **Branch** from the default branch.
2. **Make the failing case first** where this repository's discipline requires
   it, and in every case make sure the new test fails without your change.
3. **Run the gates.** All of them, or name the ones you did not.
4. **Update the surfaces.** Documentation, status tables, ledgers and generated
   artifacts that name the behaviour you changed are part of the change, not a
   follow-up. Regenerate generated files with their tooling; never hand-edit one.
5. **Open the pull request** using the template. Fill in *What this does not
   establish* — it is required, and it is the section reviewers read first.

## Claim discipline

State exactly what your change establishes and no more.

- A search that stopped at a limit reports where it stopped.
- A bounded failure is not an absence.
- A refusal is not a clean answer.
- A translation preserves or lowers authority; it never raises it.
- "Verified" unqualified is not a claim. Say verified *by what*.

## Commits

Imperative, present tense, describing the difference: `Add the M-adic ball
carrier`, `Reject a singular M before the zeroth power`. The body carries the
reasoning when the subject cannot.
