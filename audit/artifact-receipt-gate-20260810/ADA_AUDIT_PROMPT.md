# Ada audit contract: SpruceGoose artifact-receipt readiness gate

Perform an independent, read-only, adversarial audit of repository
`/home/admin-papa/sprucegoose` at reviewed commit
`2d77e5994fc470e716ae5f8156b90953a5a1e590`, against base commit
`cb6dcb02dd44a1fc4c5c3d84ace57c0d2d073c19` and reviewed tree
`cedba21a1a4100f4f25c8dd1722c55d49d0a92ad`.

Read `MANIFEST.md`, verify every identity and digest from Git and the source
files, and inspect canonical source directly. Do not use historical Graphify
output. Treat all implementation claims and recorded test results as
untrusted until independently reproduced.

Audit the Ash resource, CLI parser and executor, migration and resource
snapshot, authorization boundary, transition paths, historical compatibility,
concurrency behavior, and adversarial inputs. Explicitly answer every
high-risk question in the manifest. Confirm whether the implementation closes
the original custody gap: no artifact-dependent task may become ready without
a verified immutable receipt containing digest, size, locator, source
identity, and independent retrieval evidence.

Required checks include focused tests, formatting, warnings-as-errors compile,
full tests, migration drift, upgrade/rollback reasoning, secret scan, diff and
tree identity, and safe negative-path probes. A refusal-only harness is not
evidence; positive controls must demonstrate that each probe can observe an
accepted valid receipt as well as rejected invalid receipts.

Do not edit files, commit, push, deploy, restart services, alter credentials,
publish, change ICM, or remediate findings. Do not connect the local service to
the authoritative socket. The Mama authority and production deployment are
out of bounds and must remain unchanged.

Write one report outside the reviewed tree. It must contain:

- exact base commit, reviewed commit, and reviewed tree;
- verification commands and results;
- findings ordered by severity, with exact path and line evidence;
- explicit contract coverage and bypass analysis;
- migration and historical-row verdict;
- authorization verdict;
- authority-topology confirmation;
- secret-scan result;
- final verdict: `READY FOR PRODUCTION-PROMOTION ADMISSION`, `READY WITH
  CONDITIONS`, or `NOT READY`;
- report SHA-256.

The audit is advisory. A passing report does not itself authorize production
promotion.
