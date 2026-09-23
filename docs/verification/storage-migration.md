# Storage migration integration

Physical SQLite schema 3 introduces durable business-import decision and result
staging plus successful decision canonical receipts. The business/revision schema
and exchange protocol remain 2. Logical backup version 2 includes successful
canonical decisions; strict backup version 1 remains readable and writable by
legacy physical-v2 connections during migration.

Native host first recovers pending activation using the original physical format.
It then creates a retained `backups/before-storage-v3-*.logical` snapshot, reads it
back and verifies digest and source version, and runs the explicit atomic core
migration under the same installation lock. It closes and reopens the upgraded
connection. Existing sealed candidates are never migrated or re-signed.

Initial bootstrap resumes an owned empty file or validates an existing supported
schema. Unknown tables in a schema-zero file fail without initialization. Initial
DDL and user_version now commit together, avoiding a framework version-write
interruption window. A physical schema change also fences retained native handles.

Verification (2026-09-18):

- 34 native migration/host/restore tests passed; evidence:
  `artifacts/development/native-storage-migration-tests.log`.
- Core migration and backup lane: 111 targeted tests passed; see
  `storage-schema3.md` and `artifacts/development/schema3-tests.log`.
- Independent architecture review: `storage-migration-review.md`.
- Native scoped analysis: No issues found (`native-storage-migration-analyze.log`).
- Web Chrome 152 migration, failure/retry, old-candidate and browser restart
  checks passed; see `web-storage-migration.md` and
  `artifacts/development/platform/web-storage-migration.json`.

This is a T7 foundation slice; business import commit receipts and user-facing
import workflow are not yet complete. Android/Windows verification is deferred
per user instruction.

## Shared write context for import composition

`CommitCoordinator.commitStaged` and `TransactionPort` accept an optional held
`ApplicationWriteContext`. Same-lock active contexts execute the existing commit
path without reacquiring the non-reentrant lock. Missing context preserves normal
lock acquisition; expired or different-lock contexts fail before database access.
This permits a subsequent import service to perform backup and commit under one
lock; that service is not yet implemented.

Two new context tests plus 29 storage tests passed, independently repeated by the
architecture reviewer (31 total). Evidence: `commit-context-tests.log`. Review
found no change to identity, confirmation, validation or transaction checks.
