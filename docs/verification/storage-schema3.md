# Physical storage 3, logical business schema 2

This slice adds durable decision storage and backup compatibility; the business
import service and commit-time decision receipt publication are separate work.

`currentStorageSchemaVersion=3` and `businessSchemaVersion=2` are separate.
`SupplierDatabase(storageVersion: 2)` explicitly opens retained physical-v2
stores; default creation/opening uses 3 and never automatically upgrades 2.
Bootstrap also writes user_version inside the DDL transaction. A fault in Drift’s
subsequent version assignment therefore leaves a fully versioned reopenable
store; unknown nonempty physical-0 databases are not adopted.
`schemaStatementsForVersion` and `requiredTableNamesForVersion` select exact
physical definitions. Legacy-v2 statements remain unchanged. Candidate content
hashing retains the existing v1 hash domain, schema definition encoding, row
encoding, ordering and epoch normalization; it selects the table allowlist for
the handle's physical version, so sealed physical-v2 candidates retain their
original content identity.

`migrateStorageV2ToV3(database, expectedVersion:, context:, writeLock:)` requires
the same held application context. The host is responsible for completing a
verified durable backup and resolving old restore journals first. DDL, generation
increment and PRAGMA user_version commit in one SQL transaction; failure rolls
all three back. Generation cannot exceed the interoperable safe integer range.
Structure, foreign keys and integrity are checked inside the transaction. Retry
at physical 3 checks structure and identity, then returns without incrementing
again. Close the physical-v2 handle and reopen at 3 after success. Prepared
candidates are not upgraded or re-signed by this API.

Three added tables:

- `staging_import_decision`: job/decision PK; action, fingerprint version,
  source fingerprint/canonical, operation fingerprint/canonical, original target,
  complete decision canonical, exclusion reason. Missing source is allowed only
  for excluded errors; source/operation pairs must be complete. Only apply has an
  operation and the partial unique index rejects duplicate apply source+operation
  within a job.
- `staging_import_result`: job/decision/result PK with decision and same-job
  staging-revision FKs. Triggers require an apply decision.
- `import_decision_receipt`: event/source/operation PK, fingerprint version,
  source/operation canonical and original target, with event FK and source index.

Both staging tables use immutable-seal guards for INSERT and OLD/NEW UPDATE;
DELETE is available only through the existing terminal cleanup contract. Cleanup
removes results before decisions before staged revisions and retains seals and
successful receipts.

Physical-v2 `BackupService` emits strict backup version 1. Physical-v3 emits
version 2, adding successful decision receipts. Both retain schema_version 2.
Header table keys and columns are version-specific; v1 rejects v2 table data.
The candidate builder accepts v1 into either physical format and v2 into 3.
V1 receipt identity/results remain exact; missing operation details remain
absent. They are never reconstructed from current business data. V2 validates
canonical JSON, source/operation fingerprints, operation/source binding, field
presence, explicit intent and quantity. New detailed receipts require matching
original targets and exactly the confirmed number of distinct quotation
entities in the event result set. Legacy receipts without details retain their
original compatibility behavior.

Evidence is captured in `artifacts/development/schema3-tests.log` and
`schema3-analyze.log`. Tests exercise retained authority/settings/receipts,
reopen and retry, DDL/generation/precommit rollback, safe integer overflow,
physical-version spoofing and missing guards, v1 frozen bytes and exact legacy
service output, v1 receipt preservation, v2 canonical/quantity/target/main-result
validation, and staging seal/FK/terminal cleanup constraints. The frozen v1 file
is `packages/supplier_core/test/fixtures/backup-v1.jsonl` and is compared byte for
byte with the legacy service output.

Platform migration, restore crash replay and full import acceptance are outside
this core evidence; Android/Windows validation remains user-deferred.
