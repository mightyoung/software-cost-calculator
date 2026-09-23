# Restore capacity evidence

2026-09-18. This is a bounded formal candidate-builder test, not completion of T5.

`backup_candidate_test.dart` now exercises SQLite's actual pager allocation limit:
after creating a file-backed `SupplierDatabase`, `PRAGMA max_page_count` allows
eight additional pages. A valid logical backup contains a 200 KiB preference.
`BackupCandidateBuilder.build` fails with `database or disk is full` while staging
the backup. No mocked storage exception is used.

After closing and reopening that candidate, generation remains zero, revision,
receipt and preference tables are empty, and `integrity_check` returns `ok`.
The persistent candidate work table prevents silently retrying the interrupted
candidate as fresh. The separate source library retains its original revision,
receipt and generation. The candidate is never activated in this test.

Fresh execution: all 13 tests in `backup_candidate_test.dart` pass with Dart
3.13.3 and the resolved native SQLite package. This demonstrates isolation under
real SQLite capacity rejection, not a full disk, browser quota exhaustion, or
active-pointer interruption. The source is in memory in this fixture; only the
failed candidate is reopened from disk.

Additional deterministic concurrency evidence:

- `backup_concurrency_test.dart`: 2 PASS. A write waits during snapshot freezing;
  while external publication is paused, a write completes but the published
  backup still contains the original generation, revision and receipt.
- `native_restore_concurrency_test.dart`: 1 PASS. A commit holds the real native
  application lock while restoration starts. Once committed, restoration rejects
  its stale preview and preserves the new data and receipt.
- Both tests use awaited barriers and deadlines, not timing sleeps. Their scoped
  analysis is clean. These results were executed by the implementation agent.

Production space-estimate admission is documented in `restore-space.md`.
The later `native-restore-interruption.md` records both concurrent orderings and
actual child-process interruption at four formal activation boundaries, using a
private test Zone rather than changing the public activation API.
Android and Windows verification remains deferred by the user's instruction.
