<!--
Derived from tasks/templates/TASK.md in larsbx/agent-icm @ sha256:8f93d9b911fbccaf
Edit the canonical template or estate.toml, then re-render: make estate
Hand-edits here are drift and `make estate-check` fails on them.
-->

# Task — `<title, as an outcome>`

<!--
The shape SpruceGoose applies from `.sprucegoose/*.yaml`. Written here as prose
first so the definition of done is argued before it is encoded; `blueprint
apply` turns the encoded form into a real task in the canonical task authority,
so the queue never lives in a folder that has to be reconciled with it.
-->

- **id:** `<kebab-case, stable>`
- **kind:** openclaw
- **project / roadmap / workflow:** `<keys>`
- **depends_on:** [`<ids>`, or empty]

## Definition of done

<!--
One sentence, checkable by someone who did not do the work. It names the
artifact and the condition, not the activity.

  Bad:  "Investigate the signing key."
  Good: "The ed25519 private key matching the adapter's pinned public key is
         either located, or a decision is recorded to generate a new one and
         re-pin the adapter's public key."

Note the shape of that example: a disjunction, both branches terminating. A
definition of done that can only be satisfied by success is a definition of
done that blocks forever when the answer is no.
-->

## Input

<!-- What the task is handed. Empty is a valid answer; guessing is not. -->

## Evidence of completion

<!-- Where the proof will land: the test, the artifact, the record, the run log. -->

## Needs a named human

<!-- Yes/no. If yes: who, and for what decision specifically. -->
