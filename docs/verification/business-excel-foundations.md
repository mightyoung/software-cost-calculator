# Business Excel conversion and volume boundaries

This is T7 groundwork, not a completed XLSX reader or ExchangeService.

`business_mapping.dart` preserves raw cell type, numeric lexeme, formula presence
and coordinate. Text identifiers retain leading zeroes; numeric identifiers are
rejected instead of reconstructed. Amounts expand scientific notation using
strings, then use the existing 12+6 exact decimal validator. Missing columns,
blank cells and zero remain distinct source states. Illegal XML controls are
checked before trimming. Formula caches, booleans and error cells are rejected.

Excel serial dates use the 1900/1904 systems and reject the fictional 1900 leap
day, including its fractional times. Date-only mapping does not synthesize an
instant. An instant requires an explicit batch offset. Fractional-day conversion
uses BigInt arithmetic and exposes `millisecondsRounded`; crossing a day boundary
through rounding fails. The later preview MUST display that conversion and bind
its acknowledgement to the confirmed mapping. Returning a flag alone does not
fulfil that UI requirement. Text timestamps continue to use the existing strict
0–3 fractional-second contract, without rounding.

The serial-to-millisecond rule reconciles the approved design's separate Excel
conversion-preview path with its strict text timestamp rules; it is an
implementation interpretation, not a claim that the design explicitly permits
all date rounding. Strict OOXML/non-compatible date profiles still need explicit
handling in the workbook reader.

`bounded_zip.dart` reuses the repository's stage-0 archive 3.6.1 dependency for
DEFLATE only. It manually validates EOCD, actual central-entry count, local and
central headers, extra-field lengths, paths, non-overlapping ranges and optional
data descriptors before expanding. ZIP64, encryption and symlinks are rejected.
Both declared and actual cumulative expanded bytes are limited; decoded bytes
must match size and CRC, including unknown resources. A volume is `verified` only
after successful complete stream consumption. Early worksheet return is not
successful volume validation.

These bounds apply to ONE XLSX volume (default compressed 8 MiB, expanded 32 MiB,
2048 entries). The compressed volume and one expanded entry are held in memory;
OutputStream may grow its backing buffer beyond the logical byte count. This is
not an exact peak-RSS claim or a whole-bundle reader. Ordinary large business
workbooks require their own range/entry and persistent shared-string/row staging
path; do not silently apply synchronization's 5000-row cap to ordinary import.

Known library boundary: archive 3.6.1 does not expose proof that every DEFLATE
stream ended with a valid final block. Size/CRC checks do not prove every grammar
bit legal. The later bounded reader now adds XML parsing, relationships,
worksheet limits and persisted shared strings; its independent scope is recorded
in `xlsx-reader-review.md`. Source and operation receipts, atomic chosen-row
commit, export and actual office editing roundtrips remain pending. Historical
stage-0 tests and fixtures were not modified.

Evidence: `artifacts/development/business-mapping-{tests,chrome,analyze}.log`,
`bounded-zip-{tests,chrome}.log`; independent mapping review is recorded separately
in `business-mapping-review.md`. Count and scope follow the fresh logs, not this
progress note. Dependency/API research used the installed versions' source and
Microsoft/Open XML documentation; no package upgrade was made.
