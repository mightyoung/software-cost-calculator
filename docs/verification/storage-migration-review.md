# Physical schema 3 migration — independent architecture review

2026-09-18. Reviewer: native subagent `business_import_contract`, read-only
architectural review against `docs/implementation/business-import-contract.md`.
Verdict: CLEAR for the reviewed migration and backup compatibility slice.
This does not close T7 or the aggregate development goal.

Reviewed core migration/schema/version binding/candidate digest and v1/v2 backup
validation, native active opening/restore replay/pre-migration backup, and the
new native cross-version fixtures. Reviewer independently ran 57 targeted core
tests successfully after the fix. Web runtime evidence remains a separate lane.

One P1 was identified and fixed: initial creation previously committed DDL before
Drift separately persisted user_version. onCreate now writes physical version in
the same transaction as DDL. Unknown nonempty schema-zero databases remain
rejected; the fix does not authorize adopting unrelated tables.

No unresolved architectural blocker was reported. Verified design properties:
physical version 3 remains separate from logical version 2; migration publishes
and reads back a complete backup before DDL; schema changes, generation increment
and physical version commit atomically; retry validates complete schema without
double increment; pending old restores retain their original format/digest before
migrating the final active database; v1 details are not invented; new v2 decision
receipts validate canonical fingerprints, quantities and distinct quotation
results.

Root native runtime evidence: 34 tests passed in
`artifacts/development/native-storage-migration-tests.log`, including active and
bootstrap upgrades, backup failure preserving v2, owned empty bootstrap recovery,
unknown bootstrap rejection, and physical-v2 armed / armed_epoch / switched /
rollback_pending journal replay. These assert retained inactive files stay v2,
recorded candidate digest remains unchanged, and active generation increments once.
Android and Windows validation are user-deferred, not passed.

Follow-up context review: CLEAR. The reviewer independently repeated all 31
context/storage tests. The optional held context is checked before await/database
access, and original transaction checks remain intact. Web source review found
no initialization-order blocker but requested removal of `createMigrator()`
protected/testing API use in favor of public `Migrator(db)` before clean analysis.

Web follow-up: reviewer confirmed the public Migrator fix and independently
reran scoped analysis with No issues found; final source verdict CLEAR. Platform
lane Chrome 152 evidence subsequently passed all documented migration scenarios
and process restart (`platform/web-storage-migration.json`). Those persisted
restore boundary fixtures do not claim arbitrary-instruction kill coverage.
