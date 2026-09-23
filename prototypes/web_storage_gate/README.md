# NONPRODUCT T1 Web storage probe

Isolated Drift 2.35.0 SQL persistence, bounded read-transaction export, Web Locks,
and metadata epoch fencing experiment. See [verification report](../../docs/verification/web-storage-gate.md)
for reproducible commands, assertions, hashes, evidence and unverified boundaries.

Bundled `web/drift_worker.js` and `web/sqlite3.wasm` are unchanged copies from
`../supplier_probe/web/`. Drift is MIT licensed (https://github.com/simolus3/drift/blob/develop/LICENSE);
SQLite is public domain (https://sqlite.org/copyright.html). These are test runtime assets.
