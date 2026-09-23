# Restore space admission

The production native and Web hosts now expose `estimateRestore(source)` and
`lastRestoreEstimate`. Preparation checks the estimate while holding the application
lock, before recording or allocating a candidate. Activation rechecks capacity after
the version/candidate checks, before creating the safety backup or arming its journal.
An insufficient estimate leaves the ready candidate available for another attempt.
Journal replay and rollback never call this admission gate.

`restore-space-v1` is explicitly heuristic. Let S be source length, A the active
database's allocated main-file pages, C the prepared candidate size, and M=1 MiB.
Preparation estimates staging 2S, candidate growth 4S, journal 6S+M, two independent
safety-backup copies of 2A+M each, and M metadata/slack. Activation already has the
candidate allocated, so only journal A+C+M, the two backups and slack remain.
Existing retained files are not charged again as new space. Integer multiplication
uses BigInt before checked conversion; components, basis, version, sample time,
scope and diagnostics remain available to the later preview UI.

Native free space is currently unknown. Web uses `navigator.storage.estimate()`;
invalid, unsupported or failed sampling remains unknown with a diagnostic. A valid
sample records usage, quota and max(0, quota-usage). This is a storage-key estimate,
not physical disk free space or a reservation. See the [Storage Standard](https://storage.spec.whatwg.org/#dom-storagemanager-estimate).
SQLite allocated pages exclude WAL and temporary storage; see [page_count](https://www.sqlite.org/pragma.html#pragma_page_count).

Executed evidence on 2026-09-18:

- Core budget tests: 5 PASS, covering both phases, exact sufficiency, one-byte
  shortfall, unknown capacity, and checked multiplication.
- Native restore suite: 16 PASS (new admission test, 13 existing recovery tests,
  two lock-order concurrency tests). Rejection precedes candidate allocation;
  activation resamples and preserves the ready candidate for a later success.
- Actual bridge code in Node VM: 2 PASS, including unsupported API, rejection,
  malformed/fractional/unsafe values, and usage exceeding quota.
- Actual Chrome restore runner: PASS, including real capacity sampling, simulated
  low-space rejection at both entrances, preserved candidate, and persisted armed
  recovery with a sampler that would throw if called. Existing nine durable
  boundaries, seven fault cases and complete browser restart remain passing.

The formal SQLite FULL regression now admits a plausible budget before hitting
the pager's actual limit, demonstrating why estimation cannot replace isolation.
UI presentation and ordinary import admission are later integration work. This is
The later `actual_quota` Chrome case additionally enforces a real 1-byte origin
quota via CDP, observes browser `QuotaExceededError` despite an intentionally
sufficient estimate, and verifies original data/receipts after quota reset and
reopen. This is not physical disk-full behavior or a guarantee that all estimates
are accurate. Android/Windows verification remains deferred.
