# Interrupted full-chain run

The host process was terminated when the Codex turn was interrupted during
`restore_candidate` on 2026-09-23. No `report.json` was produced, so this run is
not a full-chain PASS. The source database and published `source.backup` remain;
`restored.sqlite` is an incomplete candidate and must not be activated or used
as a successful restore.

An independent read-only SQLite check after interruption found 500,000 valid
canonical revision hashes, 100,000 quotations, matching formal commit receipt
counts, `PRAGMA integrity_check=ok`, and no foreign-key violations in
`source.sqlite`. Its ordered authority digest is
`3f7f7485379be19648f4ddeefce27687afdaf9dace8b01ebae8699b4950867da`.
The published backup and resumed candidate require separate verification.
The published backup is 678,088,851 bytes with SHA-256
`e2aff6e38c7eb81e084323bbe59c9f29e8f950dd1b6382ddab03b370276ff8be`.
