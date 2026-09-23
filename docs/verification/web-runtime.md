# Web production adapter verification

Updated: 2026-09-23. Formal exchange adapter E2E **PASS**; real Flutter system-picker flow **BLOCKED**. These are separate scopes, and formal release remains unapproved.

Scope: `apps/supplier_app/lib/platform/web_*`, `web/supplier_platform.js`, and
`tool/drift_worker.dart`. This is the formal app adapter, separately compiled from
historical storage prototypes. Android and Windows verification is deferred by
explicit user instruction.

The Web host requires persistent OPFS and an application-wide Web Lock. Installation
identity, active pointer and activation journal use a separate IndexedDB database;
metadata writes use a strict-durability compare-and-set transaction. Existing
business databases are checked without enabling migrations. Missing identity or
active database is an error, never a silent empty-library replacement. An opened
host retains its activation identity so stale services cannot write after a switch.

File ports use at most 64 KiB ranges and output chunks. Saving closes the browser
writable stream before publication. Private artifacts are owned OPFS directories;
backup export is read back and verified before copying to its final target. File
picker handles must be acquired in the user gesture. No total-file Blob fallback
is provided.

## Drift 2.35 nested transaction defect

A real isolated Chrome run successfully opened the OPFS database and completed a
simple settings write, but hung while committing RecordService's second nested
transaction. Independent package-source review traced this to the navigator-lock
interceptor being reused by nested transaction executors: the first nested commit
completes the outer lock's release completer; the next completes it again after
the remote child has already committed. Drift then tries to roll back that removed
remote child, whose executor can never become active again.

The compatibility option `useDrift235WebLockSavepoints` is enabled only for the
pinned `WasmStorageImplementation.opfsLocks` connection. It retains Drift's outer
transaction and uses SQLite savepoints for awaited nested business SQL operations.
Native/default connections retain Drift's normal transaction behavior. This is
not a replacement for the complete nested reactive-stream transaction API.
The production worker is compiled from the app lockfile, matching its Drift client.

## Evidence and remaining scope

`tool/web_runtime_test.py` launches a disposable Chrome profile and a local server
with COOP/COEP headers. It exercises actual OPFS/IndexedDB, nested rollback,
RecordService, bounded backup readback, rejected stale metadata CAS, application
lock exclusion between two top-level pages, and browser-process reopen. Its JSON
report is written only after successful assertions; a failed attempt is retained
in `artifacts/development/web-runtime-test.log`.

Web candidate activation/recovery is implemented and verified separately in
[web-restore.md](web-restore.md). The new formal exchange adapter run below covers
business import, bundle import and safety-backup reopening. System-picker-driven
file flows and the full business UI remain pending.
This report does not establish device verification or full T5 completion. Worker lifecycle samples report observed
browser targets, not a general no-leak proof.

Latest actual run: `artifacts/development/web-runtime-smoke.json` is **PASS** for
its listed functional scope; `web-runtime-analyze.log` is clean. Independent
SAVEPOINT review reran six regression tests and approved that bounded change.
Current full core results and analysis are retained in
[final-core-tests.log](../../artifacts/development/final-core-tests.log) and
[final-core-analyze.log](../../artifacts/development/final-core-analyze.log);
these host results do not establish browser product-flow acceptance.

## Formal exchange adapter E2E

[web-exchange-smoke.json](../../artifacts/development/web-exchange-smoke.json)
and [run log](../../artifacts/development/web-exchange-run.log) record **PASS** on
isolated Chrome 153.0.8010.53. The
[runner](../../apps/supplier_app/tool/web_exchange_test.py) compiles the production
worker and [exchange harness](../../apps/supplier_app/tool/web_exchange_smoke.dart)
and passes real OPFS-backed XLSX/ZIP files to the formal app adapters. It bypasses
the system file chooser and does not drive Flutter widget clicks.

The run verifies business and bundle import, cancellation and malformed input
without successful receipts, then closes the browser process and reopens the same
profile. Both job safety-backup locators remain readable, the backups contain the
expected precommit revision counts (business 2, bundle 0), retry returns the same
receipt, and each reopened library contains one quotation. This closes the formal
adapter safety-backup locator/reopen gap for these fixtures, not the full UI or
large-file latency/memory gates.

## Real Flutter picker attempt

[web-exchange-ui.json](../../artifacts/development/web-exchange-ui.json),
[run log](../../artifacts/development/web-exchange-ui-run.log) and
[screenshot](../../artifacts/development/web-exchange-ui.png) retain a **BLOCKED**
attempt against the real release UI. The app opened, navigation reached business
import, and the genuine `showOpenFilePicker` was invoked. Chrome chooser
interception produced `AbortError`; `Page.handleFileChooser` was unavailable and
there was no HTML file input usable by `DOM.setFileInputFiles`. The picker was not
replaced. No selected-file import, full mapping/confirmation click path or UI bundle
exchange was validated by this attempt. This is an automation capability limit,
not evidence of product import failure.

The later [injected-handle UI run](../../artifacts/development/web-exchange-ui-injected.json)
and [screenshot](../../artifacts/development/web-exchange-ui-injected.png) are
**PASS within a different boundary**: actual Flutter release widgets performed
business XLSX selection, mapping, row decision and commit, then bundle export,
preview and commit. After browser restart, screenshot OCR found two task cards
and OPFS contained two nonempty task backups. The test replaced open/save handles
in the loaded page with deterministic File objects; it does not verify the native
chooser, and the formal adapter E2E remains the authority for backup contents,
locator reuse and idempotent receipts.

Real Excel/WPS save-and-return remains **BLOCKED**. The
[WPS attempt](../../artifacts/development/office-roundtrip-wps-attempt.json)
launched WPS 7.5.1 on macOS and read its version, but bounded AppleEvent document
and window operations timed out (-1712). The disposable copy stayed byte-identical
to its source; no real Office save or formal reimport was verified.

The separate native [A17 small-fixture report](../../artifacts/benchmark/a17-concurrency-checkpoint-20260923-v2/report.json)
passed 9/9 cases: complete/cancel/SIGKILL at volumes 1/5/9. This used independent
SQLite connections and a host file target; it did not exercise browser workers,
system pickers, UI or platform snapshot creation. It establishes neither a Web
concurrency result nor large-scale timing/RSS/WAL bounds; A17 remains **PARTIAL**.
Android and Windows remain **DEFERRED** by user instruction. Full-scale
import/export/backup/restore is also pending; the [100k query result](performance.md)
does not cover that chain.

## Worker lifecycle remains open

Five repeated same-page host open/close cycles observed 5, 6, 7, 8, 9 worker
CDP targets; a page-heap GC followed by a one-second wait still observed nine.
Page GC does not collect separate worker heaps. An attempted worker-session GC
diagnostic timed out and provided no conclusive reachability evidence. Thus the
cached probe avoids repeated probe construction, but deterministic per-database
worker reclamation is **not verified** and remains an explicit lifecycle follow-up.
The runner always closes its own disposable Chrome process after the test.
