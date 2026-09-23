# T1 isolated host storage experiment

Executed 2026-09-17. Scope: `prototypes/storage_gate/` only; no production adapter or old probe changes. **Host experiment PASS; Windows, Android and Web T1 release gates remain BLOCKED.** This provides executable host capability evidence only. Per the PRD, T1 remains incomplete: T3 production storage and T4 production service integration must stay closed. T2 portable rules and the T4 pure-graph draft allowed after T2 may proceed independently; these host tests do not bypass that dependency gate.

## Reproduction and raw evidence

From `prototypes/storage_gate/`, with Dart on PATH:

```sh
export PUB_CACHE=/private/tmp/supplier-inquiry-toolchain/pub-cache
dart pub get --offline
dart analyze
dart test --reporter expanded
dart build cli -t bin/probe_child.dart -o /private/tmp/storage-gate-cli
```

Actual Dart executable: `/private/tmp/supplier-inquiry-toolchain/flutter/bin/dart`.

- [Analysis](../../prototypes/storage_gate/analyze-results.txt): no issues.
- [Tests](../../prototypes/storage_gate/verified-tests.txt): 21 passed, including independent child-process lock/crash runs.
- [Native build](../../prototypes/storage_gate/build-results.txt): CLI bundle and SQLite native asset generated.
- [Compiled smoke](../../prototypes/storage_gate/build-smoke.txt): compiled child acquired and released the application lock (exit 0).
- [Source and lock hashes](../../prototypes/storage_gate/source-sha256.txt): binds tested source, fixtures, subprocess helper and dependency lockfile.

Runtime: macOS arm64 26.5.2 build 25F84; Dart 3.13.3 stable; Drift 2.35.0; Dart sqlite3 3.6.0; actual native SQLite `3.53.4`; `journal_mode=delete`; `foreign_keys=1`, `synchronous=FULL`. WAL-reset applicability is N/A for this DELETE-journal experiment. Full dependency versions are in `pubspec.lock`.

Fixture: disk database `old-instance`, generation 7; 11 integer-keyed rows `0..10`, values `value-0..value-10`, 10 parent edges `i -> i-1`. Replacement has `new-instance`, generation 7, five rows. The frozen 11-row SQLite file SHA256 observed in this run is `2a0f1cd3fbd8bcbc2ff4bb4243640c4093e145a859b89d13a30491cac012139e`; this is a physical-file hash for this runtime, not a portable logical format golden. Temporary databases are recreated by each test and cleaned after assertions.

## What passed

| Capability | Evidence and boundary |
|---|---|
| Disk persistence / FK | Close/reopen retains rows and generation; dangling parent insert rejected; integrity and FK checks pass. |
| Application lock | Eight same-isolate concurrent writers yield exactly one accepted generation-7 edit. A separate process holds the OS lock; parent cannot enter until child releases it. |
| Lock ordering | All permitted writes/activation acquire application lock before SQL transaction. Snapshot invoked from activation uses held-lock internal method, never reacquires non-reentrant lock. |
| Atomic business fixture | Failure after inserted row or before COMMIT rolls back row and generation together. After-COMMIT response failure leaves both committed. |
| Genuine SQLite capacity failure | `PRAGMA max_page_count` restricts SQLite growth; 1 MiB insert produces real `database or disk is full` / SQLITE_FULL and leaves rows and generation unchanged. This is SQLite page-limit exhaustion, not physical device exhaustion. |
| Frozen bounded scan | Explicit dedicated source read transaction, keyset pages of three rows, destination transaction; max observed row page 3. All 11 rows and 10 edges copied; identity/generation read from completed destination and file SHA256 streamed after close. |
| Snapshot failure | First, middle, final page and pre-COMMIT exceptions leave active DB unchanged; copied rows roll back. Failed output remains an internal temporary artifact and no successful Snapshot result is returned. |
| Concurrent snapshot/edit | Edit scheduled between snapshot pages waits for application lock. Snapshot remains generation 7/11 rows; active DB becomes generation 8 afterward. |
| Atomic pointer | Separate metadata SQLite transaction switches path, instance and monotonically increasing epoch; candidate is committed, checked and digest-bound first. |
| Restore version | Intervening edit invalidates expected restore generation; a refreshed attempt succeeds. Tampered candidate digest is rejected. Locked backup is current, paged, and kept separately. |
| Fencing / rollback | Old connection plus old epoch rejected after activation; same-instance snapshot connection cannot write as active DB. Reopen-check failure restores old path with a fresh epoch, invalidating both prior tokens. New writer succeeds after successful activation. |
| Process interruption | Child exits immediately (no Dart cleanup) before pointer, inside metadata transaction, or after pointer. Reopened metadata selects complete old, old, new DB respectively. New pointer rejects old-epoch writer. Startup checks selected DB integrity and identity before returning. |

## Implementation lesson

Do not nest transactions from two different Drift databases and then issue source queries inside the destination transaction: Drift's transaction zone is singular and source calls can queue behind their own outer transaction. The experiment uses an exclusive dedicated source connection with explicit SQL `BEGIN DEFERRED` / `COMMIT` / `ROLLBACK`, and a separate Drift destination transaction. Application write lock remains held throughout; writers wait. No cross-database SQL atomicity is assumed.

## Limits and remaining gates

The lock supports **one owning isolate per process**, with all local callers routed to that isolate. The static queue is isolate-local; POSIX advisory locks do not prove independent-isolate exclusion in one process. All processes must cooperate through the same canonical lock path. This is not an arbitrary-isolate or hostile-writer guarantee. Fixture connections remain open to test epoch fencing; production connection registry shutdown has not been implemented here.

This is a structural three-table fixture, not the production history graph, sealed staging, projections, receipts, migration engine, or restore job state machine. Candidate files are assumed owned and closed under this coordinator; production candidate sealing/ownership must prevent outside mutation. Raw SQL is exposed only for fixtures and can bypass coordinator fencing. Snapshot holds the application lock for the entire copy and blocks edits. No production graph-validity claims follow from SQLite integrity/FK success.

Not measured: 100k quotations/500k revisions, peak RSS, log/temp space, worst-case text width, throughput, arbitrary I/O failure, true physical disk-full, OS power loss, native filesystem rename durability, Windows process/file semantics, Android lifecycle/storage permissions, or Web OPFS/IndexedDB/cross-tab/filesystem APIs. Process exit tests establish SQLite crash recovery at selected boundaries, not hardware power-loss guarantees. No business UI, Excel/WPS roundtrip, release installation or cross-device loop was tested. These remain separate T1/T5/T11/T12 gates.
