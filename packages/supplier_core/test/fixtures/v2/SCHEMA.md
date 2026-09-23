# Frozen v2 domain and revision encoding

This fixture set belongs to domain schema version **2** and envelope protocol
**2**. The future `supplier-inquiry-bundle` container has bundle version **1**.
These versions are independent. This package does not implement a bundle codec,
DAG validation, receipt persistence or Excel import. Old prototype/v1 fixtures
are not changed or accepted as protocol-2 history.

## Scalar encoding

Canonical JSON is RFC8785 restricted to null, booleans, well-formed Unicode
strings, lists, string-keyed objects and integers from -9007199254740991 through
9007199254740991. Finite integral numeric inputs normalize to integer tokens (for example, 2.0
becomes 2); fractional and nonfinite numbers are rejected. This rule is the
same on Dart VM and JavaScript, where integral doubles also satisfy `is int`.
Canonical wire parsing still rejects noncanonical numeric spelling such as 2.0.
Object keys sort lexicographically by UTF-16 code units. UTF-8 has no BOM or
trailing newline. Control characters use JSON escapes; unpaired surrogates are
rejected. JCS itself does not normalize strings. Domain fields normalize NFC
and trim edge whitespace, reject XML-illegal characters, and count code points.
Persisted envelopes must already contain normalized payloads; local creation
normalizes before hashing. Decimal values are text, never JSON numbers.

UUID fields are lowercase UUID v4. Dates are real calendar `YYYY-MM-DD` values.
Instants persist as `YYYY-MM-DDTHH:mm:ss.SSSZ`; offset input is accepted only by
local normalization, not by strict persisted envelope parsing. Leap seconds and
fractional precision beyond milliseconds are rejected.

## Exact envelope fields

| Field | Type / constraint |
| --- | --- |
| protocol | integer 2 |
| entity_type | supplier / contact / product / quotation |
| entity_id | UUID v4 |
| parents | ascending unique lowercase 64-hex SHA256 strings |
| kind | put / delete / redirect |
| payload | object as specified below |
| authored_at | canonical UTC millisecond instant |
| origin_device_id | UUID v4 |

No missing or additional keys are accepted. `put` payloads contain all fields
below (including explicit null for optional fields); identity `id` is owned by
the envelope and not repeated inside payload. `delete` payload is `{}`.
`redirect` payload has exactly `target_id`, a UUID distinct from entity_id.
`revision_id` is lowercase SHA256 of canonical envelope UTF-8, not a field in
the envelope. Canonical envelope length is at most 24,000 UTF-16 code units.
Local `create` sorts/deduplicates parents; parsing rejects noncanonical parents.
Graph rules (one put root, same-entity parents, closure, cycles, cross-entity
references and redirect components) belong to the later graph validator.

## Exact put payload fields

`?` indicates nullable, never an omitted key. Bounds are Unicode code points.

- supplier: `name` required text ≤200; `aliases` text array ≤20 entries each
  ≤200; `address` text? ≤500; `categories` text array ≤20 entries each ≤100;
  `notes` text? ≤2000. Arrays are unique and code-point sorted.
- contact: `supplier_id` UUID; `name` required text ≤200; `phone` text? ≤100;
  `wechat` text? ≤100; `email` text? ≤254; `notes` text? ≤2000. At least one
  contact method is required. Phone remains text.
- product: `name` required text ≤200; `unit` required text ≤50; `brand` text?
  ≤200; `model` text? ≤200; `specification` text? ≤1000; `category` text? ≤100;
  `notes` text? ≤2000.
- quotation: `supplier_id`, `product_id` UUID; `price` decimal text ≥0 with at
  most 12 integer and 6 fractional digits; `currency` three uppercase letters;
  `tax_mode` included/excluded/unknown; `unit_snapshot` required text ≤50;
  `min_qty` positive decimal text with the same precision as price;
  `quoted_on` date?; `contact_id` UUID?; `contact_snapshot` object?;
  `tax_rate` decimal text? from 0–100 with at most 4 fractional digits;
  `lead_time_days` integer? 0–36500; `valid_until` date?; `notes` text? ≤2000;
  `project_name` text? ≤200; `project_number` text? ≤100; `inquiry_location`
  text? ≤500; `inquirer_name` text? ≤200; `inquiry_precision` date/instant/unknown;
  `inquiry_date` date?; `inquired_at` canonical instant?;
  `inquiry_utc_offset_minutes` integer? -840–840; `capture_mode` standard/historical.

Contact snapshot has exactly `name`, `phone`, `wechat`, `email`, with the same
name/contact-method rules as a contact. Bound contact requires a snapshot;
supplier consistency needs a later repository-backed check. `valid_until`
requires `quoted_on` and cannot precede it. Standard quotation requires project
name or number, inquirer, quoted_on and non-unknown inquiry precision. Historical
mode allows missing context. Inquiry `date` requires inquiry_date only; `instant`
requires all three time fields and local date must match UTC plus offset;
`unknown` requires all three null and historical mode.

## Version 1 local fingerprints

Both digests are SHA256 of the restricted JCS object below. These encode local
import identity, not revision history. Callers supply normalized incoming values
and canonical field names after mapping; synonym header spelling is not retained.

Source exact keys: `version:1`, `fields`, `input_identity`, `mapping_semantics`,
`batch_defaults`, `capture_mode`. `fields` maps canonical field names to exact
`{presence, value}` objects. Presence is `missing`, `blank` or `value`; missing
and blank use null, and value is non-null canonical-domain data. `input_identity`
retains original input IDs/identity text; `mapping_semantics` encodes semantic
mapping choices; `batch_defaults` contains explicit user defaults; capture_mode
is standard/historical. File name, row order/number, compression, current local
values and resolved canonical IDs are excluded. Original identity stays original
even after a supplier merge.

Operation exact keys: `version:1`, `source_fingerprint`, `intent`,
`original_bindings`, `operations`, `confirmed_quantity`. Source is the source
SHA256; intent is `modify` or `newInquiry`; original_bindings records user-selected
original IDs. Operations map canonical field names to exact `{kind,value}`
objects: keep/clear have null value; set has non-null canonical-domain data.
Quantity is a positive safe integer. Do not substitute a merged current record
for this explicit operation map. A local note changing A to B does not change
source or a prior keep operation.

A durable success receipt must additionally bind a confirmation event ID and
result IDs. Retrying the same confirmation reuses that event; another explicit
inquiry may create another event with identical fingerprints. This fixture set
only implements fingerprint values, not receipt durability/idempotent execution.

## Independent evidence

`generate.py` uses Python stdlib and an independent UTF-16 key-ordering routine.
It verifies existing `supplier-root.json`; `--write` explicitly regenerates it.
The Dart protocol test compares both canonical bytes and digest against the
frozen file. Fixture SHA256:
`d6ba013a7241d94631307e44eb6672a43d869e674f4a06feb71227dd660ce020`.

Additional independently generated vectors: `quotation-vectors.json` freezes
full date, instant (positive original offset crossing UTC year boundary), and
historical unknown-time envelopes. `fingerprint-vectors.json` freezes source
missing/blank/value states and keep/clear/set operations with both canonical
strings and SHA256 digests. `generate.py` verifies all files; protocol tests also
check the exact 24,000/24,001 UTF-16 envelope size boundary.
