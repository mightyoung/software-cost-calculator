import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../domain/canonical.dart';
import '../domain/revision.dart';
import 'bundle_manifest.dart';

/// Explicit protocol schema. Production exchange uses schema2(); the explicit
/// constructor supports isolated algorithm fixtures. Neither derives a wire
/// contract from UI labels or database column order.
final class BundleColumns {
  factory BundleColumns.schema2() => BundleColumns(schema2BusinessColumns);
  BundleColumns(Map<String, List<String>> business)
    : byKind = Map.unmodifiable({
        'revisions': List<String>.unmodifiable(revisionBundleColumns),
        for (final entry in business.entries)
          entry.key: List<String>.unmodifiable(entry.value),
      }) {
    if (business.length != 4 ||
        !bundleKinds.skip(1).every(business.containsKey)) {
      throw ArgumentError('Exactly four frozen business schemas are required');
    }
    for (final headers in business.values) {
      if (headers.isEmpty ||
          headers.first != 'entity_id' ||
          headers.length > 128 ||
          headers.any((h) => h.isEmpty || h.length > 128) ||
          headers.toSet().length != headers.length) {
        throw ArgumentError('Invalid frozen business columns');
      }
    }
  }
  final Map<String, List<String>> byKind;
}

/// Frozen supplier-inquiry-bundle v1 / business schema2 projection column order.
/// Do not derive this wire contract from domain/UI field iteration at runtime.
const schema2BusinessColumns = <String, List<String>>{
  'suppliers': [
    'entity_id',
    'revision_id',
    'relation_status',
    'name',
    'aliases',
    'address',
    'categories',
    'notes',
  ],
  'contacts': [
    'entity_id',
    'revision_id',
    'relation_status',
    'canonical_supplier_id',
    'supplier_id',
    'name',
    'phone',
    'wechat',
    'email',
    'notes',
  ],
  'products': [
    'entity_id',
    'revision_id',
    'relation_status',
    'name',
    'unit',
    'brand',
    'model',
    'specification',
    'category',
    'notes',
  ],
  'quotations': [
    'entity_id',
    'revision_id',
    'relation_status',
    'canonical_supplier_id',
    'canonical_product_id',
    'canonical_contact_id',
    'supplier_id',
    'product_id',
    'price',
    'currency',
    'tax_mode',
    'unit_snapshot',
    'min_qty',
    'quoted_on',
    'contact_id',
    'contact_snapshot',
    'tax_rate',
    'lead_time_days',
    'valid_until',
    'notes',
    'project_name',
    'project_number',
    'inquiry_location',
    'inquirer_name',
    'inquiry_precision',
    'inquiry_date',
    'inquired_at',
    'inquiry_utc_offset_minutes',
    'capture_mode',
  ],
};

final class BundleRow {
  BundleRow(this.key, List<String?> cells) : cells = List.unmodifiable(cells);
  final String key;
  final List<String?> cells;
}

/// Single-pass, volume-independent digest; only the previous identity is held.
/// Revision bytes are revision_id + TAB + canonical envelope + LF. Business
/// bytes are JCS header/row arrays + LF, including each empty table's header.
final class BundleDigests {
  BundleDigests(this.columns) {
    _revisionSink = sha256.startChunkedConversion(_revisionResult);
    _businessSink = sha256.startChunkedConversion(_businessResult);
  }
  final BundleColumns columns;
  final _DigestResult _revisionResult = _DigestResult(),
      _businessResult = _DigestResult();
  late final ByteConversionSink _revisionSink, _businessSink;
  int _kindIndex = -1;
  String? _lastKey;
  bool _finished = false;
  final Map<String, int> counts = {for (final kind in bundleKinds) kind: 0};
  void beginKind(String kind) {
    if (_finished ||
        _kindIndex + 1 >= bundleKinds.length ||
        bundleKinds[_kindIndex + 1] != kind) {
      bundleFailure('Digest tables must appear once in fixed protocol order');
    }
    _kindIndex++;
    _lastKey = null;
    if (kind != 'revisions') {
      _businessSink.add(
        utf8.encode('${canonicalJson(columns.byKind[kind])}\n'),
      );
    }
  }

  void add(BundleRow row) {
    if (_finished || _kindIndex < 0) {
      throw StateError('Digest table is not open');
    }
    final kind = bundleKinds[_kindIndex];
    if (row.key.isEmpty ||
        (_lastKey != null && row.key.compareTo(_lastKey!) <= 0) ||
        row.cells.length != columns.byKind[kind]!.length ||
        row.cells.first != row.key) {
      bundleFailure(
        'Duplicate/unordered identity or invalid row width in $kind',
      );
    }
    for (final cell in row.cells) {
      if (cell != null && cell.length > 32767) {
        bundleFailure('Cell exceeds protocol limit');
      }
    }
    if (kind == 'revisions') {
      if (row.cells.any((v) => v == null)) {
        bundleFailure('Null technical revision cell');
      }
      final revision = RevisionEnvelope.fromCanonicalJson(row.cells[3]!);
      if (revision.revisionId != row.key ||
          revision.entityType != row.cells[1] ||
          revision.entityId != row.cells[2]) {
        bundleFailure('Revision identity differs from its canonical envelope');
      }
      _revisionSink.add(utf8.encode('${row.key}\t${row.cells[3]}\n'));
    } else {
      _businessSink.add(utf8.encode('${canonicalJson(row.cells)}\n'));
    }
    _lastKey = row.key;
    counts[kind] = counts[kind]! + 1;
  }

  ({String revisions, String business}) finish() {
    if (_finished || _kindIndex != bundleKinds.length - 1) {
      throw StateError('Incomplete digest tables');
    }
    _finished = true;
    _revisionSink.close();
    _businessSink.close();
    return (
      revisions: _revisionResult.value.toString(),
      business: _businessResult.value.toString(),
    );
  }
}

final class _DigestResult implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
