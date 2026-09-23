import 'dart:convert';

import '../contracts.dart';
import '../domain/canonical.dart';
import '../domain/values.dart';

const bundleKinds = [
  'revisions',
  'suppliers',
  'contacts',
  'products',
  'quotations',
];
const revisionBundleColumns = [
  'revision_id',
  'entity_type',
  'entity_id',
  'envelope_json',
];

/// Admission budgets are supplied by the caller's space plan, not a legacy
/// 20 MiB whole-package ceiling. Per-volume limits remain protocol limits.
final class BundleBudget {
  const BundleBudget({
    required this.compressedBytes,
    required this.expandedBytes,
    required this.revisions,
    required this.volumes,
    this.manifestBytes = 1024 * 1024,
  });
  final int compressedBytes, expandedBytes, revisions, volumes, manifestBytes;
  void validate() {
    for (final value in [
      compressedBytes,
      expandedBytes,
      revisions,
      volumes,
      manifestBytes,
    ]) {
      requireSafeInteger(value, 'bundle_budget', min: 1);
    }
    if (volumes > 60000 || manifestBytes > 8 * 1024 * 1024) {
      throw ArgumentError(
        'Bundle directory budget exceeds bounded adapter capacity',
      );
    }
  }
}

final class BundleVolume {
  BundleVolume({
    required this.kind,
    required this.index,
    required this.rowCount,
    required this.sha256,
    required this.compressedBytes,
    required this.expandedBytes,
  }) {
    if (!bundleKinds.contains(kind)) bundleFailure('Unknown volume kind');
    requireSafeInteger(index, 'index', min: 1, max: 999999);
    requireSafeInteger(rowCount, 'row_count', min: 0, max: 5000);
    requireSafeInteger(
      compressedBytes,
      'compressed_bytes',
      min: 22,
      max: 8 * 1024 * 1024,
    );
    requireSafeInteger(
      expandedBytes,
      'expanded_bytes',
      min: 1,
      max: 32 * 1024 * 1024,
    );
    bundleHash(sha256);
  }
  final String kind, sha256;
  final int index, rowCount, compressedBytes, expandedBytes;
  String get path => '$kind-${index.toString().padLeft(6, '0')}.xlsx';
  Map<String, Object?> toJson() => {
    'path': path,
    'kind': kind,
    'index': index,
    'row_count': rowCount,
    'sha256': sha256,
    'compressed_bytes': compressedBytes,
    'expanded_bytes': expandedBytes,
  };
  factory BundleVolume.fromJson(Map<String, Object?> value) {
    exactKeys(value, [
      'path',
      'kind',
      'index',
      'row_count',
      'sha256',
      'compressed_bytes',
      'expanded_bytes',
    ]);
    final volume = BundleVolume(
      kind: _string(value['kind']),
      index: requireSafeInteger(value['index'], 'index'),
      rowCount: requireSafeInteger(value['row_count'], 'row_count'),
      sha256: _string(value['sha256']),
      compressedBytes: requireSafeInteger(
        value['compressed_bytes'],
        'compressed_bytes',
      ),
      expandedBytes: requireSafeInteger(
        value['expanded_bytes'],
        'expanded_bytes',
      ),
    );
    if (value['path'] != volume.path) {
      bundleFailure('Noncanonical or unsafe volume path');
    }
    return volume;
  }
}

final class BundleManifest {
  BundleManifest({
    required this.bundleId,
    required this.exportedAt,
    required this.exporterVersion,
    required this.revisionCount,
    required Map<String, int> entityCounts,
    required this.revisionsDigest,
    required this.businessDigest,
    required List<BundleVolume> volumes,
    required BundleBudget budget,
  }) : entityCounts = Map.unmodifiable(entityCounts),
       volumes = List.unmodifiable(volumes) {
    budget.validate();
    requireUuid(bundleId, 'bundle_id');
    normalizeInstant(exportedAt);
    if (!RegExp(
          r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z$',
        ).hasMatch(exportedAt) ||
        DateTime.tryParse(exportedAt) == null ||
        exporterVersion.isEmpty ||
        exporterVersion.length > 128) {
      bundleFailure('Invalid export metadata');
    }
    bundleHash(revisionsDigest);
    bundleHash(businessDigest);
    requireSafeInteger(
      revisionCount,
      'revision_count',
      min: 0,
      max: budget.revisions,
    );
    exactKeys(entityCounts, bundleKinds.skip(1).toList());
    for (final count in entityCounts.values) {
      requireSafeInteger(count, 'entity_count', min: 0);
    }
    if (volumes.length > budget.volumes) {
      bundleFailure('Volume budget exceeded');
    }
    var compressed = 0, expanded = 0, previousKind = -1;
    final counts = {for (final kind in bundleKinds) kind: 0};
    final indexes = {for (final kind in bundleKinds) kind: 0};
    for (final volume in volumes) {
      final order = bundleKinds.indexOf(volume.kind);
      if (order < previousKind || volume.index != indexes[volume.kind]! + 1) {
        bundleFailure('Duplicate, missing or unordered volume index');
      }
      previousKind = order;
      indexes[volume.kind] = volume.index;
      counts[volume.kind] = counts[volume.kind]! + volume.rowCount;
      compressed += volume.compressedBytes;
      expanded += volume.expandedBytes;
      if (compressed > budget.compressedBytes ||
          expanded > budget.expandedBytes) {
        bundleFailure('Declared bundle bytes exceed admission budget');
      }
    }
    for (final kind in bundleKinds) {
      if (indexes[kind] == 0 ||
          counts[kind] !=
              (kind == 'revisions' ? revisionCount : entityCounts[kind])) {
        bundleFailure('Missing volume or inconsistent row count: $kind');
      }
    }
    if (utf8.encode(encode()).length > budget.manifestBytes) {
      bundleFailure('Manifest budget exceeded');
    }
  }
  final String bundleId,
      exportedAt,
      exporterVersion,
      revisionsDigest,
      businessDigest;
  final int revisionCount;
  final Map<String, int> entityCounts;
  final List<BundleVolume> volumes;
  Map<String, Object?> toJson() => {
    'format': 'supplier-inquiry-bundle',
    'bundle_version': 1,
    'schema_version': 2,
    'bundle_id': bundleId,
    'exported_at': exportedAt,
    'exporter_version': exporterVersion,
    'revision_count': revisionCount,
    'entity_counts': entityCounts,
    'revisions_digest': revisionsDigest,
    'business_digest': businessDigest,
    'volumes': volumes.map((v) => v.toJson()).toList(),
  };
  String encode() => canonicalJson(toJson());
  factory BundleManifest.decode(List<int> bytes, BundleBudget budget) {
    budget.validate();
    if (bytes.length > budget.manifestBytes) {
      bundleFailure('Manifest budget exceeded');
    }
    try {
      final value =
          _UniqueJson(utf8.decode(bytes)).parse() as Map<String, Object?>;
      exactKeys(value, [
        'format',
        'bundle_version',
        'schema_version',
        'bundle_id',
        'exported_at',
        'exporter_version',
        'revision_count',
        'entity_counts',
        'revisions_digest',
        'business_digest',
        'volumes',
      ]);
      if (value['format'] != 'supplier-inquiry-bundle' ||
          value['bundle_version'] != 1 ||
          value['schema_version'] != 2) {
        throw const DomainFailure(
          'UNSUPPORTED_FORMAT',
          'Unsupported bundle version',
        );
      }
      final raw = value['volumes'] as List;
      if (raw.length > budget.volumes) bundleFailure('Volume budget exceeded');
      return BundleManifest(
        bundleId: _string(value['bundle_id']),
        exportedAt: _string(value['exported_at']),
        exporterVersion: _string(value['exporter_version']),
        revisionCount: requireSafeInteger(
          value['revision_count'],
          'revision_count',
        ),
        entityCounts: (value['entity_counts'] as Map<String, Object?>).map(
          (k, v) => MapEntry(k, requireSafeInteger(v, k, min: 0)),
        ),
        revisionsDigest: _string(value['revisions_digest']),
        businessDigest: _string(value['business_digest']),
        volumes: raw
            .map((v) => BundleVolume.fromJson(v as Map<String, Object?>))
            .toList(),
        budget: budget,
      );
    } on DomainFailure {
      rethrow;
    } catch (error) {
      throw DomainFailure(
        'CORRUPT_BUNDLE',
        'Invalid manifest JSON',
        cause: error,
      );
    }
  }
}

Never bundleFailure(String message) =>
    throw DomainFailure('CORRUPT_BUNDLE', message);
void bundleHash(String value) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    bundleFailure('Invalid SHA256');
  }
}

String _string(Object? value) {
  if (value is! String) bundleFailure('Expected manifest text');
  return value;
}

/// jsonDecode loses duplicate object keys. This bounded parser checks keys at
/// every nesting level before constructing the manifest's semantic objects.
final class _UniqueJson {
  _UniqueJson(this.text);
  final String text;
  int at = 0;
  void whitespace() {
    while (at < text.length && ' \r\n\t'.contains(text[at])) {
      at++;
    }
  }

  bool take(String token) {
    whitespace();
    if (text.startsWith(token, at)) {
      at += token.length;
      return true;
    }
    return false;
  }

  void need(String token) {
    if (!take(token)) throw const FormatException('JSON token expected');
  }

  String string() {
    whitespace();
    final start = at;
    need('"');
    while (at < text.length) {
      final c = text[at++];
      if (c == '\\') {
        at++;
      } else if (c == '"') {
        return jsonDecode(text.substring(start, at)) as String;
      }
    }
    throw const FormatException('Unterminated JSON string');
  }

  Object? value(int depth) {
    if (depth > 16) {
      throw const FormatException('JSON nesting exceeds manifest limit');
    }
    whitespace();
    if (at == text.length) throw const FormatException('Missing JSON value');
    if (text[at] == '"') return string();
    if (take('{')) {
      final result = <String, Object?>{};
      if (take('}')) return result;
      do {
        final key = string();
        need(':');
        if (result.containsKey(key)) {
          bundleFailure('Duplicate manifest key: $key');
        }
        result[key] = value(depth + 1);
      } while (take(','));
      need('}');
      return result;
    }
    if (take('[')) {
      final result = <Object?>[];
      if (take(']')) return result;
      do {
        result.add(value(depth + 1));
      } while (take(','));
      need(']');
      return result;
    }
    final start = at;
    while (at < text.length && !',]} \r\n\t'.contains(text[at])) {
      at++;
    }
    return jsonDecode(text.substring(start, at));
  }

  Object? parse() {
    final result = value(0);
    whitespace();
    if (at != text.length) throw const FormatException('Trailing JSON');
    return result;
  }
}
