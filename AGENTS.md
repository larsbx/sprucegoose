<!--
Derived from templates/docs/AGENTS.md in larsbx/agent-icm @ sha256:e0ea75600e3d136a
Edit the canonical template or estate.toml, then re-render: make estate
Hand-edits here are drift and `make estate-check` fails on them.
-->

# Agent policy — sprucegoose

The estate's task authority and governed-release control plane.

**Language / toolchain:** Elixir 1.19, escript plus an OTP release
**CI:** GitHub Actions: `ci.yml` (fast checks, then tests under scram-sha-256 and trust), `delivery.yml`, `dependency-audit.yml`; Woodpecker via `.woodpecker.yml`

This file is for whoever is working here next, human or otherwise. It states
what is settled, so that it does not get re-litigated by someone reading only
the code.

## Read first

- `README.md`
- `docs/`
- `.sprucegoose/project.yaml`

## Gates

Before proposing a change as finished, run:

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

Report honestly which ran. A partial environment that reports a skip is worth
more than one that passes vacuously.

## What this repository treats as evidence

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

## Scope discipline

- Make the change that was asked for. If the surrounding code is wrong in a way
  the task did not name, say so — do not widen the diff to fix it.
- If something is blocked, finish everything that is not, and say precisely what
  was left and why.
- Where a decision is already recorded, follow it or reopen it explicitly. Do
  not route around it in code.
