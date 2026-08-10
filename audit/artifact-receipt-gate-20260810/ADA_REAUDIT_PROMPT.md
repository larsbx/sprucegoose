# Ada re-audit contract: trusted artifact custody remediation

Perform an independent, read-only, adversarial re-audit of repository
`/home/admin-papa/sprucegoose` at remediation commit
`cd4496dc5f7704ec4d746dedea98b8049ea8264f`, tree
`d057bc5ffc5c549362a5e16f02bf5f01a30078a0`. The controlling prior audit is
`ADA_AUDIT_REPORT.md`, SHA-256
`9a96fe25f8720e28f208bab27b4db0f46060f213f5d002964bbab6aaeb088ed5`.

Read `REMEDIATION_MANIFEST.md`, independently verify every Git identity, byte
count, and digest, and inspect canonical source directly. Treat all remediation
and verification statements as untrusted claims. Do not use historical Graphify
output.

For each prior finding, construct both a positive control and an adversarial
negative control. In particular verify:

- digest and size are computed from retrieved bytes, not supplied by a caller;
- the CAS locator is digest-bound and stored content cannot be silently replaced;
- source replacement or mutation during retrieval is refused;
- zero-byte, non-regular, oversized, malformed, extra-field, future-time, and
  locator/digest mismatch cases fail closed;
- receipt creation requires a distinct authenticated verifier and dual-role
  verifier/operator authority is refused at relevant scope;
- Ash transition, move, direct SQL, and legacy refresh paths cannot admit an
  artifact-dependent task without complete canonical receipts;
- concurrent writers preserve or reject evidence without lost updates;
- historical rows remain compatible without fabricated receipts;
- rollback refuses evidence loss once requirements or receipts exist;
- the compiled CLI can complete a valid end-to-end custody flow.

Reproduce focused tests, full tests, formatting, warnings-as-errors compile,
migration drift, clean upgrade, destructive-rollback refusal, and a secret scan
with a positive-control scanner check. Confirm the exact Papa/Mama authority
topology before and after.

Do not edit the reviewed tree, commit, push, deploy, publish, restart services,
alter credentials, change ICM, or remediate findings. Use disposable Papa-local
resources only. Do not connect a local service to the authoritative socket. Mama
and production promotion are out of bounds.

Write one report outside the reviewed tree with exact identities, commands and
results, severity-ordered findings with path/line evidence, disposition of every
prior finding, bypass and rollback analysis, authority-topology confirmation,
secret-scan result, and one verdict: `READY FOR PRODUCTION-PROMOTION ADMISSION`,
`READY WITH CONDITIONS`, or `NOT READY`. Supply the finalized report SHA-256.

The report is advisory and cannot itself authorize production promotion.
