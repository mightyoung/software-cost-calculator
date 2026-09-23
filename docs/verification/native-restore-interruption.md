# Formal native restore interruption and lock ordering

2026-09-18, macOS host only. Windows and Android remain user-deferred.

`tool/native_restore_interrupt.dart` prepares a real isolated native library,
logical backup and candidate through production services. A separately launched
Dart process activates that candidate. It reports an awaited checkpoint, then
waits indefinitely; its parent delivers SIGKILL to that exact child handle.
No close, rollback or finally cleanup runs in the terminated child.

Four fresh cases pass (`native-restore-interrupt.json` and `.log`):

- `before_switch`: candidate epoch persisted, independent pointer still old.
- `inside_switch`: active-pointer UPDATE executed inside the metadata transaction,
  before journal UPDATE or transaction completion.
- `after_switch`: pointer and switched journal committed atomically.
- `after_accept`: new connection checks and accepted/used transaction committed.

Every child exits with signal status -9. Opening a new host recovers the complete
candidate at the expected epoch, with exactly the snapshot supplier and unchanged
device identity. A subsequent new supplier remains after another close/reopen;
accepted data does not automatically roll back.

Fault checkpoints use a private Zone lookup. Only the test-support helper and
developer tool install the callback; the public host constructor and restore API
have no fault-injection parameter. Default application execution has no callback.

`native_restore_concurrency_test.dart` now verifies both orderings with awaited
barriers and deadlines. Commit-first makes restoration reject `stale_preview`.
Restore-first holds the real application lock, then a staged writer starts; after
activation it rejects `stale_active_database`, with no success receipt or revision
in the restored library. The combined native restore/admission suite is 16 PASS;
fresh output is `native-restore-admission-tests.log`.

This establishes process interruption at these explicit production boundaries,
not random instruction interruption, OS power loss, physical disk failure or all
platform lifecycle behavior. The separately documented Web tests retain their
durable-fixture scope. Independent review is recorded separately.
