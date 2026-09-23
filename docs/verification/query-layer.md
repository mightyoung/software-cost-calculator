# T6 SQL query layer

Implementation: `packages/supplier_core/lib/src/query/`, typed schema in
`data/tables.dart`, affected projection installation in `data/projection_writer.dart`.

## Public contract

`QueryRepository.quotations(filters, cursor:, limit:)` returns typed quotation rows;
`quotationHeads(entityId, ...)` pages explicit conflict heads. Default page size is
50, accepted limits 1–200. The cursor binds instance, activation epoch, generation,
normalized filter/as-of digest, sort key and entity ID. Any database version change
requires a fresh query. Sorts are inquiry date descending, quoted date descending,
and exact decimal price ascending; null dates/prices sort last.

Filters are a whitelist. Values are SQL parameters. Product/supplier/contact IDs,
product name/brand/model, project name/number, inquirer, inquiry/quotation date
ranges, inquiry precision/missing, missing context, price range, currency, unit,
tax mode/rate and minimum quantity have typed handling. Inquiry timestamps are
never synthesized. Comparison `as_of` is explicit or comes from the injected
calendar clock, defaulting to the current local calendar date.

History retains rows whose associations are deleted, redirected, conflicted or
anomalous. Conflict summaries have no chosen payload. Filtering a conflict checks
that one current put head satisfies the complete predicate; callers page all heads
for details. Reverse dependencies include every head, so later target merges
refresh conflicted quote canonical references. Historical product identification
terms survive tombstones and parallel non-put heads. Product text matches original
and canonical identities.

Confirmed comparison excludes unknown/future quotation dates, unknown/expired
validity, unknown tax and unusable supplier/product relations. It groups by
canonical product, unit, currency, tax mode, minimum quantity and included-tax rate
(including a distinct unknown rate). Per-supplier latest date ties are retained,
then every exact minimum-price tie is returned. Monetary ordering uses validated
fixed decimal keys, never floating-point comparison.

Candidate results contain stable IDs and matching fields/reasons. No candidate is
automatically merged. Relation presentation uses joins rather than per-row reads.
Exact and prefix term lookups use indexed normalized keys; contains is a separate
scan path. Search normalization is frozen as
`nfkc-casefold-16.0-whitespace-v1` (Unicode 16 full casefold, NFKC and whitespace
collapse); original NFC payload text and model punctuation remain unchanged.

## Verification and limits

`test/query_test.dart` covers stable pages, version/filter cursor rejection,
conflict branch matching, exact decimal extremes, ties, eligibility, tax grouping,
normalization, literal wildcard characters, surrogate-gap prefix ranges, deleted
and merged identification, all-head dependency refresh and actual SQLite plans.
The full-core tests, analyzer and compiled executable SQL/query smoke are recorded
under `artifacts/development/query-*`.

`tools/generate_benchmark.dart` is an explicit, unexported query-only structural
fixture generator with seed 641921. It refuses an existing output path and buffers
at most a bounded batch. The 10k/100k quotation fixtures contain 50k/500k canonical
revisions respectively, plus supplier/product/contact entities and typed
projections. Generation uses a native SQLite file, 64 MiB SQLite cache, and
synchronous OFF only for this disposable fixture. This does not test durable writes
or the product graph-validation pipeline. Reports include actual query EXPLAIN
plans and individual first-query timings; these are not p95 or platform acceptance.
Contains scans, temporary sort/group trees and full-graph validation per business
commit remain relevant to T11. Android/Windows validation is explicitly deferred.

## Native file measurement (2026-09-17/18)

Both runs completed. The 100k file contains 100,000 quotation projections and
500,000 canonical revisions; its file size is 1,965,322,240 bytes. The 10k file is
196,399,104 bytes. The producer queue never exceeded 3,200 rows. SQLite cache was
64 MiB; no process peak-RSS claim is made. Fixture generation took 42.110 s for
10k and 2,483.798 s for 100k. Generation bypasses product graph writes and uses
synchronous OFF, so these times do not establish import or durability performance.

Single first-page samples in milliseconds (not p95, not a controlled cold-cache
comparison; the 10k run overlapped 100k generation):

| Query | 10k quotations | 100k quotations |
| --- | ---: | ---: |
| `history` | 64.637 | 147.040 |
| `quoted_history` | 47.738 | 237.656 |
| `price_history` | 33.815 | 251.891 |
| `product_history` | 4.936 | 14.239 |
| `supplier_history` | 2.005 | 16.859 |
| `project_person` | 5.879 | 254.350 |
| `confirmed_lowest` | 2.033 | 8.315 |
| `product_name_prefix` | 196.351 | 4536.092 |
| `product_name_contains` | 13.040 | 4317.373 |

Product-name history prefix/contains queries take over four seconds at 100k and
motivated the bounded optimization measured below. Exact product/supplier filters and the
product-scoped confirmed-lowest query are much narrower; their samples cannot be
generalized to an unfiltered comparison. Candidate exact/prefix EXPLAIN uses the
`candidate_term` composite key, with bounded search-key ranges for prefix; prefix
also uses temporary group trees. Contains scans the entity-type owner index. The
complete plans, including join/filter/sort branches, are saved in
`artifacts/development/query-10k.json` and `query-100k.json`.

Reproduce from `packages/supplier_core` with the configured Dart SDK and a new
output path (existing paths are refused):

```sh
dart run tools/generate_benchmark.dart --count=10000 --path=/tmp/query-10k-new.sqlite --report=../../artifacts/development/query-10k-new.json
dart run tools/generate_benchmark.dart --count=100000 --path=/tmp/query-100k-new.sqlite --report=../../artifacts/development/query-100k-new.json
```

The fixture measures the reviewed query projection/index layout. Later additions
to task-source metadata do not alter that layout. Platform/device tests, read
latency distributions and product commit/import throughput remain separate gates.

## Bounded history-page optimization

The original plan performed display joins and sorted wide rows across the matched
history before applying LIMIT. History now materializes only ordered entity IDs
and sort keys first, then loads payloads and joined display data for at most 201
rows (requested limit + 1). All filter/cursor predicates are inside that page;
conflict-head matching and the comparison query remain unchanged. No additional
index or full-database in-memory cache was added.

`query-100k-optimized.json` records a run on an APFS clone of the original 100k
fixture, with three warmups and 20 measured rounds per query, 64 MiB SQLite cache,
and nearest-rank p95 (19th of 20 sorted samples):

| Product-name history query | Warm p95 | Maximum | Target | Result |
| --- | ---: | ---: | ---: | --- |
| Prefix | 257.943 ms | 267.477 ms | <=500 ms | Pass on this native host run |
| Contains | 75.710 ms | 1126.465 ms | <=2000 ms | Pass on this native host run |

The full samples and result-ID stability digest are retained. The actual plan
shows `MATERIALIZE page` before `SCAN page` and the payload/display joins. The
original first-query samples are not equivalent to these warm p95 samples; no
speedup ratio is asserted. These results do not establish Android, Windows or Web
performance, nor general T11 completion.

The measurement mode executes only SELECT/EXPLAIN and connection cache settings.
It uses a disposable clone because Drift's native read transactions issue
`BEGIN IMMEDIATE`, which SQLite `query_only` rejects; it does not claim an
engine-enforced read-only handle. No fixture index/data mutation was needed.

```sh
dart run tools/generate_benchmark.dart --measure-existing=/tmp/query-100k-clone.sqlite --rounds=20 --report=../../artifacts/development/query-100k-optimized.json
```

Both fixture files completed read-only SQLite `quick_check`, full
`integrity_check` and `foreign_key_check`: checks returned `ok`, with no FK
violations. Actual 100k-file counts are 500,000 revisions, 100,000 quotation
projections, 10,000 suppliers, 20,000 products and 20,000 contacts. Evidence:
`artifacts/development/query-fixture-integrity.log`. This separate validation used
a bounded 256 MiB SQLite cache and ran after the latency samples.
