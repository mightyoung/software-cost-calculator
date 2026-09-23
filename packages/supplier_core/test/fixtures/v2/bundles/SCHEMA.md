# Frozen bundle v1 / schema2 business projections

The release column contract is `schema2BusinessColumns` in
`lib/src/exchange/projection_digest.dart`, returned by `BundleColumns.schema2()`.
The earlier two-column `digest-vector.json` is a test-only algorithm vector;
it is not the release schema.

All entities are represented, including tombstones, redirects and conflicts.
Rows are in binary ascending entity UUID order. A unique head supplies its
revision ID; parallel heads have a null revision ID and null payload fields.
Only a unique `put` head supplies payload fields. Relationship status follows
the persisted graph validator; no wall-clock winner is selected.

String values are exact text. Null is a blank XLSX cell and JSON null in the
logical digest; empty text remains a distinct empty string. Integers are
canonical base-10 text. Arrays and structured contact snapshots are restricted
JCS JSON text inside one cell. Canonical reference columns are derived from the
validated graph, retaining the original reference IDs in the payload columns.

Column order (each line is one exact header array):

```json
["entity_id","revision_id","relation_status","name","aliases","address","categories","notes"]
["entity_id","revision_id","relation_status","canonical_supplier_id","supplier_id","name","phone","wechat","email","notes"]
["entity_id","revision_id","relation_status","name","unit","brand","model","specification","category","notes"]
["entity_id","revision_id","relation_status","canonical_supplier_id","canonical_product_id","canonical_contact_id","supplier_id","product_id","price","currency","tax_mode","unit_snapshot","min_qty","quoted_on","contact_id","contact_snapshot","tax_rate","lead_time_days","valid_until","notes","project_name","project_number","inquiry_location","inquirer_name","inquiry_precision","inquiry_date","inquired_at","inquiry_utc_offset_minutes","capture_mode"]
```

Type order is suppliers, contacts, products, quotations. SHA256 covers each
type's JCS header array plus LF, then each JCS row array plus LF. Empty types
still contribute their header. Revision digest is independently SHA256 of
ascending `revision_id + TAB + canonical_envelope + LF` lines.

Changing any of these column orders or encoding rules requires a new explicit
schema version and migration fixtures; it must not silently change schema2.
