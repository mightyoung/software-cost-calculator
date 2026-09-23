# Supplier inquiry stage-0 probe

Isolated Dart/Drift/SQLite and XLSX feasibility probe. It is not the business app or the revision DAG synchronizer. No login, backend, identity or security workflow is added.

Use Dart 3.13.3 (bundled in Flutter 3.47.4):

```sh
dart pub get
dart analyze
dart test
dart run bin/probe.dart create /tmp/supplier-a.sqlite /tmp/supplier.xlsx
dart run bin/probe.dart verify /tmp/supplier-a.sqlite
dart run bin/probe.dart import /tmp/supplier.xlsx /tmp/supplier-b.sqlite
dart run bin/probe.dart verify /tmp/supplier-b.sqlite
```

Create/import require empty database files. Re-import refuses to overwrite. Close and re-run `verify` to test process-level persistence. File output errors are surfaced; creation and XLSX export are separate operations, not one filesystem/database transaction.

The workbook has `manifest`, `suppliers`, `contacts`, `products`, `quotations` sheets. `lib/model.dart:columns` freezes exact English headers and ordering. All scalar cells are text; nullable values are blank; lists and contact snapshots are JSON text. Manifest rows are `format | supplier-inquiry-stage0-snapshot` and `schema_version | 2`. Formulas, numeric/date/error cells, unknown schema, missing/reordered/unknown headers and unknown sheets are rejected. Ordinary Excel sheets are not supported by this probe.

Project name, project number, inquiry timestamp, offset, location and inquirer are quotation snapshots. They do not define uniqueness or a user/project entity. UTC milliseconds plus offset preserve the entered wall clock on export. Quoted date remains separate. NFC and exact decimal strings apply throughout. SQL price sorting uses a fixed-width decimal key; no floating conversion.

Import preflights compressed and actual expanded ZIP bytes (20 MiB/200 MiB), entry count (2048), method, size and CRC with bounded DEFLATE output before XLSX parsing. Parser/UI heap and CPU worst cases still need production profiling. Restore fully validates the snapshot, then inserts in one transaction; nonempty target is always refused. A v1 database migration appends nullable context fields; it does not implement or rewrite revision hashes.

Platform evidence must be recorded separately. Passing native Dart tests on macOS is not proof of Android, iOS, Windows, browser persistence or Excel/WPS interoperability. Flutter product shell and full DAG synchronization remain outside this probe.

Browser probe:

Parser compatibility limits: merged cells and inconsistent/duplicate parent row coordinates are rejected before parsing. Invalid Unicode scalars and XML characters are rejected. Multi-run inline text and inline CRLF are explicitly rejected because excel 4.0.6 can alter them; supported text preserves internal content.

The real WPS saved fixture is `../../artifacts/supplier-probe/supplier-wps-roundtrip.xlsx`. WPS adds built-in accounting format declarations 41–44 that excel 4.0.6 refuses globally. After validating the original archive and raw text cell types, the importer removes only these declarations from an in-memory copy when no actual cellXfs uses them directly or through xfId inheritance. Other low format IDs, used overrides and nontext cells fail explicitly. Source XLSX bytes and all cell content remain unchanged; this is a narrow tested compatibility boundary, not general style repair.

```sh
curl -fL https://github.com/simolus3/drift/releases/download/drift-2.35.0/sqlite3.wasm -o web/sqlite3.wasm
curl -fL https://github.com/simolus3/drift/releases/download/drift-2.35.0/drift_worker.js -o web/drift_worker.js
dart compile js web/main.dart -o web/main.dart.js
python3 -m http.server 8080 --directory web
```

Open `http://localhost:8080/?database=probe-unique-name&action=seed`, close/reopen the browser, then open the same database name without `action`. The page exposes the chosen Drift backend, reads its durable data and runs the shared XLSX roundtrip. In-memory fallback disables writes/download and never reports persistent success. Storage eviction outside the app remains possible; this technical probe is not a backup UI. Wasm assets must be downloaded from the matching pinned Drift release; no service worker/offline bootstrap is provided here.
