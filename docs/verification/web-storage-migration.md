# Web physical storage 2 → 3 migration

2026-09-18. Business schema/protocol remain 2. This verifies the isolated Chrome
OPFS + IndexedDB path, not Android, Windows, or the full T7 business importer.

The host holds `withApplicationWriteContext` over recovery, opening, backup and
migration. It replays any old activation journal before migrating the chosen
active library. Existing databases open with `enableMigrations:false`; a no-op
`QueryExecutorUser` reads the actual SQLite version before constructing a
version-matched `SupplierDatabase`. Sealed candidates remain physical v2 with
unchanged content digests. Active migration increments generation, invalidating
old prepared-candidate expectations.

Before DDL, `BackupService` publishes a durable OPFS backup, then `decodeBackup`
reads its persistent locator and checks digest and full database version. An
independent IndexedDB record `storage-migration:<backup locator>` retains that
locator, digest, instance, epoch and generation before the explicit core SQL
migration. Failure creating the private artifact aborts the already-owned durable
output. SQL DDL, generation and physical version use the core migration's single
transaction. The host closes the v2 handle and reopens/verifies physical v3.

Only `create:true` with physical version 0 and no non-SQLite schema objects can
initialize. A raw-probed OPFS worker may retain its open executor after close and
reopen, so initialization explicitly invokes the core atomic `onCreate` with a
public `Migrator`; automatic Drift migration remains disabled. Active version 0
and nonempty bootstrap version 0 are rejected. New active-version reads also
reject a physical-version mismatch with the opened handle.

Run from repository root (with `DART` pointing to the locked Dart 3.13.3 SDK and
localhost excluded from proxies):

```sh
python3 apps/supplier_app/tool/web_storage_migration_test.py
```

The runner compiles the current worker and smoke program, creates a disposable
Chrome profile, serves local COOP/COEP headers, and runs:

- v2 → v3 with settings preserved and generation 7 → 8;
- private artifact creation failure, owner abort, unchanged v2/generation, retry;
- IndexedDB migration-record failure before DDL, unchanged v2/generation, retry;
- corrupted published-backup readback rejection before DDL and retry;
- existing v2 bootstrap and entirely empty version-0 bootstrap recovery;
- rejection of active version 0 and nonempty bootstrap version 0;
- sealed old candidate version/digest preservation and stale preview rejection;
- original v2 `armed`, `switched`, and `rollback_pending` journals recovered before
  migrating the finally selected database;
- complete browser shutdown/restart, physical-v3 reopen, generation still 8.

Fresh results and exact browser version are in
`artifacts/development/platform/web-storage-migration.json`; compile/run output is
`web-storage-migration-run.log`, browser output is `web-migration-chrome.log`, and
targeted static analysis is `web-storage-migration-analyze.log`. The restore
states are explicit durable boundary fixtures; they do not claim arbitrary
instruction-level process termination coverage. Core migration DDL/commit fault
injection is maintained independently in the core test suite.
