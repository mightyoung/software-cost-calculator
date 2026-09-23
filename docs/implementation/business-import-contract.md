# T7 durable import and storage evolution

Accepted implementation direction, 2026-09-18, based on the independent
business-import-contract architecture review of approved PRD §3.4 and T7.
This is an implementation contract, not completed evidence.

Physical SQLite storage advances from 2 to 3; business schema, confirmation
tokens, job inputs and revision/synchronization protocol remain 2. Existing
physical-v2 data is retained. Automatic Drift upgrades remain forbidden: the
platform first holds the installation lock, finishes pending restoration in its
original physical format, opens the active database without auto-migration,
creates and reads back a complete durable logical backup, then explicitly
migrates in one SQL transaction. New DDL, generation+1 and user_version=3 commit
together. Reopen verifies the actual version; retries never increment twice.
Prepared restore candidates are not migrated or re-signed. Active migration
invalidates their old expected generation; pending journals recover before it.

Add three tables:

- staging_import_decision: job/decision primary key, apply/skip/excludeError,
  source fingerprint/canonical, optional operation fingerprint/canonical,
  original target, strict complete decision canonical and exclusion reason.
- staging_import_result: job/decision/result revision primary key, foreign keys
  to the decision and that job's staging_revision.
- import_decision_receipt: event/source/operation primary key, fingerprint
  version 1, source and operation canonical, original target; event FK.

Existing import_row_receipt retains the main result revision set. Successful
tables contain applied operations only. Excluded/error/skipped rows never count
as already imported. Same source+operation within one job is one explicit
quantity decision; duplicate rows cannot silently disappear. Modify quantity is
one; newInquiry creates exactly the confirmed number of distinct main entities.
Auxiliary supplier/product/contact revisions do not increase that quantity.
No original target is represented by the already permitted empty string, never
by a newly resolved alias/canonical identity.

Staging uses the existing seal/terminal-cleanup trigger pattern. Business preview
computes its decision digest from durable decisions and result allocations,
including exclusions and conversion acknowledgements. Original source identity
excludes filename/row number/current values; task decision digest may include row
coordinates. Bind active identity/epoch/generation before matching and check it
again before sealing. Do not change the existing revision digest algorithm or
re-sign old jobs. Before commit, validate canonical hashes, main-result quantity,
staging membership and event result membership.

Under the same application write context: check existing confirmation success,
validate preview, make the current-library backup, and commit. The coordinator
must accept an existing held context to avoid recursive locking. Its existing
final transaction copies only apply decisions and result receipts together with
revisions, projections, generation and commit_receipt. Persist confirmation and
all chosen IDs/times before commit; retries query/reuse that event and result set.

Source lookup joins successful commit receipts before candidate matching and
paginates original operations/results. New logical backups use backup_version=2,
schema_version=2 and include successful decision canonical data. Keep strict v1
decoding: old receipts retain their identity/results and are labeled as missing
legacy operation details; never reconstruct keep/clear/set from current values.

Required new tests cover migration backup/DDL/commit failures and reopen,
generation increment once, old pending restoration/candidate digest handling,
v1/v2 backup compatibility, retry-stable events, local edit/delete/alias changes,
exclude without successful source receipt, explicit quantities, sealed decision
tampering and transaction rollback without partial receipts. Android/Windows
verification remains user-deferred.

## Reviewed commit semantics for quotation business imports

The first implementation slice handles the existing `modify` and `newInquiry`
intents. Its final transaction must prove the saved operation agrees with the
materialized revision, in addition to verifying canonical hashes.

- Every staged quotation revision belongs to exactly one applied decision, and
  distinct decisions cannot share the same main quotation entity/result.
  Skipped/excluded decisions have no results; their abandoned staged quotation
  or auxiliary revisions must be removed before sealing, never silently applied.
- `newInquiry` requires a fresh quotation ID, root put and valid standard payload.
  Declared set/clear operations must equal the resulting fields. With no prior
  baseline, keep has no defined meaning and is rejected before sealing.
- `modify` requires one existing quotation with one current put head. The result
  parents and persisted expected heads equal that baseline. Deleted, redirected
  or conflicted targets use their dedicated flows. Missing/keep field operations
  preserve the baseline; only explicit set/clear may change a field.
- Operation keys are quotation payload fields and comparisons use normalized
  canonical values. These checks precede authority installation; receipt copying
  cannot reinterpret newly inserted results as the old baseline.
- Auxiliary supplier/product/contact revisions in this quotation-import slice
  are new put roots directly required by selected quotations' original reference
  IDs. Shared new auxiliaries are allowed. Referencing an existing supplier does
  not authorize editing its name or attributes. Independent auxiliary imports
  require their own explicit operation contract.

These are completion criteria for the bounded receipt/commit slice. They do not
claim the matching UI or unrestricted large-workbook adapter exists.

## Workbook mapping and explicit historical entry

`BusinessImportWorkflow` now accepts the actual prepared `XlsxStaging`, job ID,
`BusinessMapping` and device identity. `previewPage`/`previewRow` convert bounded
cell pages, preserve missing versus blank columns, expose conversion details,
look up successful source receipts before name candidates, and expose original
record states plus an available export revision baseline. Incoming IDs never
automatically select a target. Column positions and row numbers stay outside the
source fingerprint; mapping semantics, capture mode and explicit defaults remain
inside it. Field conversion types are constrained: identifiers stay text, prices
remain exact decimal strings, and Excel/local times require explicit date/offset
semantics.

`decide` accepts explicit modify/newInquiry/importHistorical/skip/excludeError
choices, selected references, optional supplier/product creation, set fields,
clear fields, quantity and conversion/reprocessing acknowledgements. It creates
and validates revision envelopes inside the application service. A blank update
preserves the baseline, clearing requires an explicit field choice, known deleted,
redirected or conflicted targets require their dedicated record flow, and a prior
successful source cannot apply again without explicit reprocessing. Newly selected
contacts copy the current snapshot and must belong to the selected supplier.

`importHistorical` is an additive operation intent: the source must explicitly
use historical capture, the original target must be empty, and every main result
must be a fresh historical quotation root. It does not weaken newInquiry's
standard-context requirement or modify's expected-head checks. The receipt and
backup decoders enforce this distinction, including logical restore. Supplier,
product and price remain mandatory for historical imports.

`summary`/`seal` require one durable decision for every actual worksheet data row
and the exact confirmed mapping configuration. Unvisited rows cannot disappear
when a caller confirms one page. Applied main quotation quantities, skipped rows
and explicit exclusions are reported separately. Decisions are immutable within
a task; changing a confirmed mapping or row choice uses a new task. Reopening with
the same task, staging and mapping retains its decisions, and final confirmation
continues to use the service's persistent retry-stable event and double receipts.

Verification lives in `test/business_workflow_test.dart`: actual XLSX reader and
writer, RecordService seeding/editing, normal ExchangeService commit/backup,
historical-root rejection cases, and BackupCandidateBuilder restore are used.
The bounded input ZIP budgets remain unchanged; this evidence is not an Excel/WPS
desktop editing roundtrip or unrestricted ordinary-large-workbook acceptance.
