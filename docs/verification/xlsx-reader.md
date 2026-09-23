# Bounded XLSX raw-cell reader

2026-09-18. This slice supplies an event-based raw-cell adapter and isolated SQL
staging; it does not complete T7 business import/export.

## API and persistence

`BoundedXlsxReader(maxDataRows: 5000).readVolume(input, staging, sheetName:, checkpoint:)`
reads one bounded XLSX through `BoundedXlsxZip` (8 MiB compressed / 32 MiB total
expanded / 2048 entries). Default row policy is 5000 data rows plus one header.
The row limit is explicitly configurable independently of ZIP/entry budgets;
5002 actual rows are tested with a 6000-row policy. This is not a completed
ordinary large-workbook range/entry pipeline or a 100k-row acceptance result.

The profile records date1904, selected sheet, actual row/cell/shared-string counts,
source digest and selected row budget. The digest hashes the bytes consumed by
the ZIP reader. Spreadsheet dimensions are not trusted as actual row counts.

`XlsxStaging(QueryExecutor)` owns a separate disposable database, never the
business executor. Shared strings are inserted individually; the lookup cache is
at most 32 strings. Row metadata and cells have separate keyset pages (defaults
50 rows / 32 cells, caller limits 1..200), so wide rows cannot inflate a row page.
Only a successful complete ZIP expansion, including CRC validation of unrelated
last entries, publishes `ready`. Failed and incomplete runs are not readable via
the page/profile API. Ready and unfinished state are tested across disk reopen.

Raw cells preserve coordinates, original type, style index, numeric lexical text,
shared/inline/rich text, and formula presence including empty shared-formula nodes.
Formulas, booleans, errors and ISO-date `t=d` remain row-level mapping errors rather
than preventing inspection of the whole workbook. `t=d` conversion is currently
unsupported by business mapping, not silently treated as text. Styles are retained
as indices; no automatic style-based date or number conversion is performed.

The awaited checkpoint runs before reading, per 1 MiB consumed source, between
entries, per 64 strings/rows or 256 cells, and before ready. It runs in the caller
zone so it can inspect a separate JobStore, must not re-enter the same staging
connection, and must not launch detached work. Cancellation preserves the original
error and quarantines the staging result. Parsing one already bounded XML token is
synchronous; checkpoints do not claim instruction-level interruption.

## Strict XML and compatibility boundary

XML uses lazy `parseEvents`, with nesting/document/parent validation enabled, not
an Excel workbook DOM. Extra lexical checks reject DTD, missing/unquoted attribute
assignments, malformed/unknown entities, illegal characters, scalar child elements,
misplaced/duplicate coordinates, unsupported rich-text children, merged cells and
oversized UTF-16 cell values. Token and depth budgets apply before event aggregation.

SpreadsheetML ST_Xstring is decoded exactly once for text. `_x000D_` preserves CR;
`_x005F_x0041_` remains the literal `_x0041_`. Decoded controls and isolated
surrogates are rejected. This follows the [Microsoft ST_Xstring notes](https://learn.microsoft.com/en-us/openspecs/office_standards/ms-oe376/bd0aa042-434a-4ca7-b25f-4e1fd25a954d).

Unknown namespaces are not globally ignored. Two precisely located non-business
metadata shapes are recognized for the checked-in WPS workbook:

- `workbook/extLst/ext` with URI `{B58B0392-4F1F-4190-BB64-5DF3571DCE5F}`:
  `2018/calcfeatures:calcFeatures/feature`, only the feature's `name` attribute,
  no business text or arbitrary descendants.
- `styleSheet/extLst/ext` with URI `{EB79DEF2-80B8-43e5-95BD-54CBDDF9020C}`:
  `2009/9/main:slicerStyles`, only `defaultSlicerStyle`, no child elements or text.
  This is not general slicer support.

MC Ignorable prefixes must be bound; that declaration does not authorize unknown
business children to be dropped. Other MC instructions (including MustUnderstand,
ProcessContent, Preserve variants and unknown instructions), AlternateContent,
and other unsupported extension structures fail explicitly. Full MC preprocessing,
Strict OOXML namespace support, arbitrary OPC layouts and full XSD validation are
not claimed. The bounded profile requires canonical workbook/shared-string paths;
selected worksheet paths resolve through checked workbook relationships.

## Evidence and remaining work

Final targeted validation: **59/59 VM tests passed**, **17 real Chrome cases
passed**, plus complete browser restart with OPFS staging persistence. Scoped
Dart analysis is clean. Both existing `supplier-sample.xlsx` and
`supplier-wps-roundtrip.xlsx` quotation sheets passed (2 rows / 42 cells), with
exact assertions for D2 `12.340001`, Q2 `000123-A`, and R2
`2026-09-16T14:30:00.123+08:00`.

Detailed VM output: `artifacts/development/xlsx-vm-tests.log`.
Actual isolated Chrome OPFS SQLite and full process restart:
`xlsx-web-smoke.json`, `xlsx-web-run.log`. Analysis: `xlsx-analyze.log`,
`xlsx-web-analyze.log`. Existing artifact probe: `xlsx-existing-smoke.log`, with
quotation coordinates/types/lexical values; this is reuse of older saved artifacts,
not a newly performed Office/WPS editing round trip.

T7 still needs ordinary workbook scaling/profile integration, headers and mapping
workflow, row-error selection, source/operation receipts, atomic selected-subset
commit, XLSX writer/export and fresh Office/WPS round trips. No business database
schema, revision authority or import confirmation API is changed by this slice.
