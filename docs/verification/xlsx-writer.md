# Bounded XLSX text writer

2026-09-18. This is a single-volume primitive, not completion of T7 export or the
snapshot/volume/bundle coordinator.

`BoundedXlsxWriter.encodeVolume` consumes a stream of fixed-width string/null rows,
explicit headers and a fresh isolated `XlsxStaging` for verification. It returns a
`BoundedXlsxVolume`, exposing bounded `InputSource` ranges, actual byte/row counts,
expanded bytes and SHA-256. No activity against the business database is implied.

`XlsxExportPolicy.syncVolume` enforces at most 5000 data rows, with the header
counted separately. `boundedBusiness` requires its own explicit row budget. Both
remain within this adapter's 8 MiB compressed / 32 MiB actual expanded / 2048-entry
ceilings; caller byte budgets may tighten but not raise them. The package contains
six fixed entries. This adapter retains one bounded volume/worksheet in memory;
32 MiB expanded bytes is not a 32 MiB peak-memory claim. Outer bundles must not
accumulate volumes into a whole-bundle Blob. Automatic shrinking/splitting and
ordinary large export orchestration remain future service responsibilities.

Every non-null cell is `inlineStr` with a text style. No field passes through a
floating-point, date or formula conversion. Null is an explicit blank cell; an
empty string is an empty text cell. Missing columns are not padded: mismatched row
width fails. Unicode, combining marks, whitespace, CR/LF, exact decimals, leading
zero identifiers and caller-supplied UTC timestamps are preserved. XML escaping
and one-pass ST_Xstring encoding preserve even overlapping literal sequences such
as `_x005F_x0041_`. Cells exceeding 32767 UTF-16 units or containing illegal XML
characters/isolated surrogates fail. Formula-looking strings remain literal text.
Worksheet names use an explicitly constrained profile; names resembling an
ST_Xstring escape are rejected until semantic sheet-name decoding is supported.
CR, LF and tab are rejected in worksheet names to avoid XML attribute whitespace
normalization changing the name.

The writer hashes ordered coordinates/kinds/lexical values as it writes. It then
feeds the complete generated XLSX through the production reader into the supplied
fresh staging database, checks counts and file digest, and recomputes the cell
hash through bounded SQL pages. No volume is returned on a mismatch. This caught
and fixed a real overlapping-ST_Xstring defect during development.

`BoundedXlsxVolume.publishTo(target)` writes copies in at most 64 KiB chunks,
checks cancellation, then publishes. Any failure triggers abort, retaining the
primary error/stack plus abort failure/stack. Encoding itself takes no output
ownership: callers must clean up a target they opened before a failed encode.
Publication has the platform OutputTarget semantics; it does not prove a browser
download was physically saved by the user. Checkpoints are awaited; synchronous
compression of one already bounded entry is not instruction-level interruptible.

`businessQuotationColumns` defines stable field keys and Chinese headings for all
quotation payload fields, display labels, four non-authoritative matching hints
(record ID/type/export revision/template version), and missing-context hints.
The template version is `1`. A future export service supplies validated values,
canonical contact-snapshot JSON and display hints; headers are not used to guess
business field identity. Supplier/contact/product export adapters are not provided
by this quotation-template constant.

## Verification

- 25/25 VM tests: `artifacts/development/xlsx-writer-vm-tests.log`.
- 7 actual Chrome cases with OPFS publication, file readback, and full browser
  restart: `xlsx-writer-web-smoke.json`, `xlsx-writer-web-run.log`.
- Scoped core and Web smoke analysis: clean (`xlsx-writer-analyze.log`,
  `xlsx-writer-web-analyze.log`); Python syntax and diff check clean.
- Tests cover raw text/Unicode/UTC, null versus empty, formula-looking text,
  maximum cell length, real 5000-row boundary, explicit policy separation,
  actual expanded/compressed budgets, source failure, cancellation, fresh staging,
  output errors and dual cleanup failures, and sink-mutation isolation.
- Reviewable generated sample: `artifacts/development/business-export-v1.xlsx`,
  33 columns and one data row; exact bytes/hash in `xlsx-writer-artifact.json`.
  This is a synthetic sample with matching hints, not authoritative sync history.

The package uses standard transitional SpreadsheetML parts/text styles consistent
with the reader's existing Excel/WPS fixtures. Fresh Microsoft Excel and WPS
open/edit/save/reimport validation is still required; reader self-verification and
older artifact compatibility must not be reported as that round trip. Consistent
snapshot acquisition, full export services, job integration, volume coordination
and outer-bundle streaming are outside this slice.
