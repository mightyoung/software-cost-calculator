# T7/T8 execution progress

This is a working progress record, not a replacement for the approved plan.
G004 remains in progress; G001–G003 have separate completed checkpoints.
Android and Windows validation is deferred by the user.

Completed foundation slices:

- Bounded XLSX reader/staging and writer with raw cell semantics, OPFS checks,
  strict ZIP/XML handling and legacy WPS fixture readback. This does not yet
  provide the uncapped ordinary-business workbook adapter or fresh Office edit
  roundtrip.
- Physical storage 3 / logical protocol 2, strict logical backup versions 1/2,
  explicit backed-up migration and retained candidate compatibility. See
  `../verification/storage-migration.md`, `storage-schema3.md`, and
  `web-storage-migration.md`.
- Optional held write context in the existing commit coordinator, preserving
  non-reentrant installation lock ordering.

Current slice under verification:

- `ImportReceiptStore` durable apply/skip/excludeError decisions, streamed digest,
  main-result validation, successful source/operation keyset lookup and atomic
  receipt copy primitive.
- `JobStore.sealBusinessPreview` computes the digest from persisted decisions
  under the original source attempt version. Coordinator revalidates it in the
  final transaction and copies applied receipts with revisions/projections.
- Business commit tests cover explicit quantity, auxiliary-result exclusion,
  response loss/reopen, failure rollback, opaque digest rejection, excluded rows,
  stale matching version and immutable sealed decisions.

Still required for this stage:

- Durable reuse of one confirmation event per explicit confirmation and complete
  current-library backup before import commit under the same held write context.
- Source-first lookup integrated with candidate matching, explicit keep/clear/set
  choices, exclusions, quantities and conversion acknowledgements in the UI.
- Complete ordinary business workbook streaming path and large-input behavior.
- Full supplier/product/contact/quotation UI, import/export flows and T8 acceptance.
- Follow the later G005/G006 sync/conflict and scale/release goals; do not mark the
  aggregate objective complete from foundation tests.
