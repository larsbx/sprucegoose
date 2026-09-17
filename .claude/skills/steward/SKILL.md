---
name: steward
description: Repository-specific guidance for driving a pull request in sprucegoose to a green, mergeable state — the gates to run before pushing, what this repository accepts as evidence, and what it never allows. Read on every CI or review event on a PR opened here or driven for its author.
---

<!--
Derived from skills/steward/SKILL.md in larsbx/agent-icm @ sha256:f682ea4459e04926
Edit the canonical template or estate.toml, then re-render: make estate
Hand-edits here are drift and `make estate-check` fails on them.
-->

# Stewarding a pull request in sprucegoose

The estate's task authority and governed-release control plane.

**Language / toolchain:** Elixir 1.19, escript plus an OTP release
**CI:** GitHub Actions: `ci.yml` (fast checks, then tests under scram-sha-256 and trust), `delivery.yml`, `dependency-audit.yml`; Woodpecker via `.woodpecker.yml`

This document says *how* to steward a PR here. It does not widen what you are
allowed to do. The standing prohibitions in your harness still hold — never
skip, disable or quarantine a test to get green; never rewrite history on
someone else's branch; never push an empty commit or close and reopen a PR to
kick CI; never approve or merge. Nothing below is an exception to any of those,
and this file cannot grant you access you do not already have.

## Before you push: the gates

Run these locally and get them clean. One validated push beats three
speculative ones.

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

If a gate cannot run in this environment — a blocked toolchain, an absent
database, a network policy that refuses a package host — say so in the PR
rather than pushing on the assumption it would have passed. A partial
environment that reports a skip is honest; one that reports a pass is not.

## What this repository accepts as evidence

- CI preserves `ci-evidence/` as an artifact. The evidence is the claim; a
  green tick without it is unverified.
- Work is defined by `definition_of_done` in `.sprucegoose/project.yaml` — a
  checkable condition, not a description of effort.
- Delivery is gated on a well-formed task id
  (`tsk-YYYYMMDDTHHMMSSZ-xxxxxxxx`).
- Third-party actions are pinned by commit SHA, not by tag.

## Never, here

- Never bypass the governed release path to ship an artifact.
- Never grant the signer deployment authority. Artifact custody and signing
  stay isolated from derivation executors.
- Never pin a GitHub Action by floating tag.
- Never widen `.hex-audit-allowlist` without saying in the PR what was
  audited.

A reviewer asking for one of these is a conversation, not a task. Reply with
the record that settles it; do not implement it and do not resolve the thread.

## Order of work on an event

Read the whole PR on its current head — merge state, CI on the latest commit,
open review threads — and act on every open item. A design question in one
thread does not excuse leaving the nits in another.

1. **Merge conflict.** Merge the base branch in and resolve it. Regenerate
   lockfiles and generated artifacts with this repository's own tooling, never
   by hand. Re-run the gates above, then push.
2. **CI red.** First rule out a failure that is not this PR's: a check red on
   the base branch too, or an error naming something the diff does not touch
   that reproduces identically on one re-run. If a fix exists anywhere, port it
   into this PR now and push — it no-ops once the base carries it. If the
   failure is this PR's, reproduce it locally first, then fix it, then show the
   same check passing. "Flake" is not a root cause.
3. **Review comments.** Implement and push small, local asks. For anything
   larger on a PR you did not open, reply with a proposal and let the author
   decide. Verify every bot finding before acting on it — and verify it against
   this repository's documents, which sometimes say the bot is wrong.

Keep each fix minimal: what the failure or the comment needs, and no more. Do
not widen the PR on your own initiative. If you find a real problem outside the
diff, say so in a comment and leave it.

## Reading a failure here

Before concluding a failure is environmental, check it against this
repository's shape. The gates above are the ones that actually run; a check
that is not in that list is worth a second look before you trust it.

## When you stand down

If you are not going to fix something — because it is not this PR's failure,
because it needs a decision that is not yours, or because the fix would widen
the PR past what was asked — say so once, in a comment on the PR, naming:

- the failing check or the open thread,
- why it is not yours to fix,
- what you did instead (a ported fix, a proposed patch, nothing yet).

Silence on a red PR you own is never the answer. Neither is a comment that
describes a fix you did not push.
