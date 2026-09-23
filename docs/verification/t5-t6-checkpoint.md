# T5/T6 implementation checkpoint

2026-09-18. This checkpoint covers G003, not the remaining product milestones.
Android/Windows verification is deferred by the user's explicit instruction.

| Required area | Current implementation and executed evidence |
| --- | --- |
| Complete logical backup, settings and successful receipts, device exclusion | Backup format/service/candidate tests and independent `backup-core-review.md`; source snapshot is frozen under the application lock, external publication uses the verified private artifact. |
| Candidate isolation, version binding, independent durable pointer, old-host fencing | Native and Web production hosts, canonical candidate digest, native recovery suite and Chrome boundary matrix; `native-restore-architecture.md`, `web-restore.md`. |
| No lock inversion or recursive lock acquisition | Existing write context plus two backup concurrency tests; both native commit/restore orderings finish with precise stale errors. |
| Actual activation interruption and accepted-write retention | Four real native child SIGKILL boundaries, including inside the independent metadata transaction; `native-restore-interruption.md` and its separate review. Web durable fixtures plus full browser restart retain their narrower scope. |
| Range input, streaming publication, source loss/reselection and cancellation | Native file ports, Web real File/range tests, and JobStore's 12 tests; `file-job-review.md`. No whole-package Blob fallback. |
| Persistent job states and retry identity | Source digest binding, sealed attempt immutability, version/CAS checks, confirmation identity and committed-receipt proof; terminal failed/cancelled states are not revived. |
| Space estimates and actual capacity rejection | Two-phase production admission with unknown native availability; actual native SQLite FULL after sufficient estimate; Chrome 1-byte origin quota returns real QuotaExceededError, then reopening preserves pre-failure version/data/receipts. `restore-space.md`, `restore-capacity.md`, `web-restore.md`. |
| Typed query filters, missing values, stable pagination and exact comparison | Query repository/candidates/comparison tests and independent `query-review.md`; unknown dates and abnormal relationships remain visible in history. |
| Query plan and fixed-scale initial measurements | `query-layer.md`, actual EXPLAIN and 100k quotation/500k revision fixture with integrity checks and 20 warm query rounds. Full import/export and memory release gates remain T11. |

The integrated core suite reached 285 PASS before the separately developing
writer slice. Native restore/admission/concurrency suite: 16 PASS. Full core/app
analysis was clean after space integration; the subsequent private native test
seam has clean scoped analysis. Raw logs and browser JSON live in
`artifacts/development/` and independent reviews identify their exact scopes.

Later required work is still active: T7 business mapping/coordinator, source and
operation receipts, large ordinary workbook integration, subset commits and
export; T8/T10 complete UI; T9 snapshot bundles/conflicts; T11/T12 full-scale,
release and final invariant review. Reading old WPS samples is not a new real
Office edit/import round trip, and narrow query measurements do not close T11.
