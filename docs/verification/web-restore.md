# Web restore implementation evidence

2026-09-18 — bounded T5 Web restore slice, not completion of all T5/platform acceptance.

`WebDatabaseHost.prepareRestore(source)` builds an isolated OPFS candidate through
`BackupCandidateBuilder`, closes it, and persists its generation and canonical
content digest in the independent IndexedDB candidate record. The installation
identity is retained; a source backup never replaces the device ID.

`activateRestore(candidateId)` holds the installation Web Lock, checks the preview
instance/epoch/generation, creates a full logical safety backup, then reopens and
validates that backup through its durable OPFS UUID locator. The independent IDB
journal is armed only after that verification. Atomic multi-record IDB CAS switches
the active pointer and journal. Candidate content is checked both before epoch
rebinding and on a fresh connection after publication. The canonical digest ignores
only `database_meta.active_epoch`; it includes schema, projections and settings.

Opening a host replays armed/switched journals before exposing business services.
Failures enter rollback_pending and restore the retained old database at
`new_epoch + 1`; the retained generation must still match. Reopening after the old
epoch has already been updated completes the pending pointer CAS. Accepted journals
never cause automatic rollback, so subsequent accepted writes remain authoritative.
Old hosts compare their original identity and epoch with IDB on each coordinated
write. Database validation retains foreign keys, integrity checks, synchronous FULL,
and the opt-in Drift 2.35 opfsLocks nested-transaction compatibility flag.

Primary errors and stacks are preserved alongside cleanup failures and their stacks.
The Web opener's shared probe ownership is unchanged by this slice.

## Executed evidence

- Scoped Dart analyze: clean (`artifacts/development/web-restore-analyze.log`).
- Dart-to-JS compilation of the real worker and restore smoke: PASS.
- Actual isolated Chrome with OPFS and IndexedDB: PASS
  (`artifacts/development/web-restore-smoke.json`, `web-restore-run.log`).
- Normal restore replaces two-record active data with the one-record snapshot,
  retains device ID, and preserves the full two-record safety backup.
- Both original-host and separately loaded peer-tab business writes are rejected
  after activation.
- Durable state fixtures cover armed, armed_epoch, switched, rollback_pending,
  rollback_epoch, settings tampering at switched and armed_epoch, projection
  tampering at switched, and missing safety backup. Valid candidates accept;
  invalid candidates recover the retained library with an increased epoch.
- Invalid input during preparation and stale generation during activation leave
  the active library unchanged and do not arm an activation journal.
- A complete browser process stop/start with the same disposable profile recovers
  an armed_epoch fixture. The safety backup remains readable by its stored locator.
  An already accepted library retains a subsequent business write across that restart.
  The test checks the exact names `after-accepted` and `snapshot` (excluding
  `retained`) and matches the reopened instance to the activation result.
- JavaScript syntax, Python runner compilation, and `git diff --check`: clean.
- Seven additional failure paths pass in the actual Chrome adapter: private
  artifact creation, durable write, durable close/publication, actual IDB
  transaction abort at arm/switch/accept, and a lost response after a successful
  acceptance CAS. Pre-journal failures preserve the original epoch and content;
  switch/accept aborts recover the retained library at epoch 2. Lost acceptance
  response retains the accepted candidate at epoch 1 on reopen.
- Output ownership covers failure before `BackupService` acquires its private
  artifact: the already opened durable target is aborted exactly once. Completed
  outputs are not aborted again.
- Real browser `File` objects and bounded range reads exercise source binding:
  simulated read loss is rejected, renamed identical bytes are accepted, changed
  bytes are rejected without changing the stored digest, and cancellation leaves
  business generation and records unchanged.
- A later real quota run uses CDP `Storage.overrideQuotaForOrigin` to set this
  disposable origin's effective quota to **1 byte**, verifies `overrideActive`,
  and attempts production activation with an intentionally stale, sufficient
  estimate. The browser returns an actual `QuotaExceededError`; no fake storage
  error is thrown in this case. Removing the override and reopening preserves
  both original suppliers, two successful receipts, instance/epoch/generation,
  and an unarmed activation journal. Evidence: `actual_quota` in the smoke JSON
  and `web-restore-quota-run.log`. The complete prior matrix also passed.
  The final run records Chrome/152.0.7977.84, a failure at durable output creation,
  comparison against the version captured before applying the limit, and
  `overrideActive:false` after reset. Activation's sufficient preflight was reached.

Runner: `apps/supplier_app/tool/web_restore_test.py`; it compiles its worker into its
own output directory and does not edit the shared runtime runner or worker source.
Set `DART` to the Dart SDK executable and `PUB_CACHE` to the resolved package cache.

## Scope limits

The interruption states are explicit durable boundary fixtures followed by host or
full browser restart; they are not instruction-level kill/fault injection. Browser
physical disk exhaustion and actual permission revocation are not established.
The real quota test is a browser-enforced CDP limit; the separately named seven
fault tests still inject quota/read-loss/close errors through wrappers. IDB aborts
use real transactions, but do not simulate physical I/O failure. No large backup restore
memory/latency or Android/Windows acceptance is claimed. UI wiring, candidate/backup
retention cleanup policy and user-facing recovery selection remain outside this slice.
Failed or abandoned candidate files and safety backups are retained, never silently
deleted. The safety backup is bound by the full logical stream digest and candidate
content by canonical database digest; no physical OPFS file-byte equivalence is claimed.
