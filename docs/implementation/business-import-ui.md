# Business Excel application workflow

The standalone `BusinessImportPage` receives a `BusinessImportWorkflowAdapter`.
Factories supply `NativeBusinessImport` (exchange, device ID, application-owned
staging directory) or `WebBusinessImport` (exchange, device ID, namespace). The
page does not create revision envelopes or access business tables directly.

The native entry requires an absolute file path. The Web entry calls the existing
browser file picker directly from the button gesture. Worksheet discovery is
followed by full bounded XLSX validation of the explicitly selected worksheet.
Users choose the header row, standard/historical capture mode, field mappings,
optional batch defaults and an explicit offset for local times without a zone.
Mappings use the core field conversion contract, preserving text identifiers and
exact decimal amounts. Header choices display at most 100 columns explicitly.

Rows are paged ten at a time. Original cell types/text, conversion previews,
conversion errors, candidate reasons, original record state, available export
baseline and successful old operations are visible. Previous and newly committed
result revisions are read in bounded pages. Every actual data row must receive a
durable decision; unvisited/error rows cannot disappear from final confirmation.

The row dialog supports modify, new standard inquiry, explicit historical import,
skip and exclusion with a reason. Existing supplier/product IDs and candidates
require explicit confirmation; users can instead explicitly create either entity
in the same transaction. Field controls distinguish using incoming data, keeping
the current value, clearing and setting a specified value. Conversions and
reprocessing successful source rows require separate acknowledgements.

The final summary separates modifications, new inquiries, historical imports,
skipped rows, exclusions and resulting quotation count. Only its final confirmation
button seals and commits the task. Backup failure, stale generation, cancellation
or any commit failure cannot produce a success message. Confirmed row choices and
mapping are immutable within the task; changing them requires a new task.

Parsed staging is durable in a named native SQLite file or OPFS database keyed by
job ID. Mapping configuration is retained with its parsed profile; row decisions
remain in core durable staging. A user can copy the displayed job ID and restore
the task after leaving/restarting. Ready and committed tasks reload the original
core-owned seal and confirmation event; retry does not allocate a new event.
Interrupted parsing and missing staging are rejected with a fresh-task instruction.

Tests: `business_import_native_test.dart` performs real file creation, selection,
parsing, mapping, row decision, process-style close/reopen, commit, second reopen
and idempotent confirmation. `business_import_page_test.dart` exercises the real
widget flow from file path to final commit and a missing-file failure. These host
tests are not Android/Windows acceptance. Browser picker/OPFS runtime coverage and
real Excel/WPS desktop editing roundtrips require their separate evidence.
