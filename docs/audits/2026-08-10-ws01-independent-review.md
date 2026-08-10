# WS-01 independent review receipt

- Review task: `tsk-20260807T201427Z-954ebb4a`
- Specification: `SPEC-SPRUCEGOOSE-REMEDIATION-2026-08-07`
- Reviewed commit: `8b76e25729cce7e7057cb0677406310c81981970`
- Review scopes: specification compliance; code quality and security

## Initial verdicts

Both independent reviews returned `FAIL` on the first commit. They identified these material gaps:

1. The recurrence test called the worker manually and did not prove future cron occurrences or runtime wiring.
2. The crash-window test returned an error instead of stopping after external success and before database accounting.
3. The dispatcher leased up to 100 rows for one minute and processed them serially. Later rows could be reclaimed before delivery.
4. Outcome writes had no ownership fence. A stale claimant could overwrite a newer claim's accounting.
5. Exception coverage did not prove progression to dead-letter state.
6. Runtime configuration did not reject a loaded module that lacked `deliver/1`.

## Resolution

The workstream commit was amended to:

- prove three consecutive future cron occurrences and evaluate the enabled runtime configuration;
- stop a linked dispatcher after observed external success but before accounting, then prove lease-expiry redelivery with the same event key;
- claim, deliver, and account for one event before claiming the next;
- make the lease at least one minute and 30 seconds longer than the configured handler timeout;
- fence each outcome update by event ID, pending status, and the exact claimed lease timestamp;
- prove that a stale claimant cannot change a newer lease or its accounting;
- prove that a raised exception reaches dead-letter state at attempt 20;
- reject an invalid handler module during runtime configuration.

## Final verdicts

- Specification-compliance review: `PASS`
- Code-quality and security review: `PASS`
- Focused verification: `31 tests, 0 failures`
- Full verification: `223 tests, 0 failures`
- Production compile and release construction: exit `0`

Neither reviewer edited the repository. The known Ash, Postgrex, and ymlr advisories remain assigned to WS-11 and continue to block final promotion.
