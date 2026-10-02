import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'canonical.dart';
import 'quotation.dart';
import 'values.dart';

/// Immutable protocol-2 envelope. Graph closure, root uniqueness and reference
/// validity are checked by the graph validator, not by this local value type.
final class RevisionEnvelope {
  RevisionEnvelope._(
    this.entityType,
    this.entityId,
    this.parents,
    this.kind,
    this.payload,
    this.authoredAt,
    this.originDeviceId,
  );

  factory RevisionEnvelope.create({
    required String entityType,
    required String entityId,
    required List<String> parents,
    required String kind,
    required Map<String, Object?> payload,
    required String authoredAt,
    required String originDeviceId,
  }) {
    final normalizedParents = parents.toSet().toList()..sort();
    return RevisionEnvelope.fromJson({
      'protocol': 2,
      'entity_type': entityType,
      'entity_id': entityId,
      'parents': normalizedParents,
      'kind': kind,
      'payload': kind == 'put' ? validatePayload(entityType, payload) : payload,
      'authored_at': normalizeInstant(authoredAt),
      'origin_device_id': originDeviceId,
    });
  }

  factory RevisionEnvelope.fromJson(Map<String, Object?> json) {
    exactKeys(json, const [
      'protocol',
      'entity_type',
      'entity_id',
      'parents',
      'kind',
      'payload',
      'authored_at',
      'origin_device_id',
    ]);
    if (json['protocol'] is! num || json['protocol'] != 2) {
      throw const FormatException('Expected envelope protocol 2');
    }
    final type = json['entity_type'];
    if (type is! String ||
        !const ['supplier', 'contact', 'product', 'quotation'].contains(type)) {
      throw const FormatException('Unknown entity_type');
    }
    final id = requireUuid(json['entity_id'], 'entity_id');
    final device = requireUuid(json['origin_device_id'], 'origin_device_id');
    final rawParents = json['parents'];
    if (rawParents is! List) {
      throw const FormatException('parents must be an array');
    }
    final parents = <String>[];
    for (final parent in rawParents) {
      if (parent is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(parent) ||
          (parents.isNotEmpty && parents.last.compareTo(parent) >= 0)) {
        throw const FormatException(
          'parents must be sorted unique SHA256 identifiers',
        );
      }
      parents.add(parent);
    }
    final kind = json['kind'];
    final rawPayload = json['payload'];
    if (rawPayload is! Map || rawPayload.keys.any((key) => key is! String)) {
      throw const FormatException('payload must be an object');
    }
    final payload = Map<String, Object?>.from(rawPayload);
    switch (kind) {
      case 'put':
        final normalized = validatePayload(type, payload);
        if (canonicalJson(normalized) != canonicalJson(payload)) {
          throw const FormatException('Persisted payload is not normalized');
        }
      case 'delete':
        exactKeys(payload, const []);
      case 'redirect':
        exactKeys(payload, const ['target_id']);
        if (requireUuid(payload['target_id'], 'target_id') == id) {
          throw const FormatException('An entity cannot redirect to itself');
        }
      default:
        throw const FormatException('Unknown revision kind');
    }
    final authoredAt = json['authored_at'];
    if (authoredAt is! String || normalizeInstant(authoredAt) != authoredAt) {
      throw const FormatException(
        'authored_at must be canonical UTC milliseconds',
      );
    }
    final result = RevisionEnvelope._(
      type,
      id,
      List.unmodifiable(parents),
      kind as String,
      _freeze(payload) as Map<String, Object?>,
      authoredAt,
      device,
    );
    if (result.canonical.length > 24000) {
      throw const FormatException('Envelope exceeds 24000 UTF-16 units');
    }
    return result;
  }

  factory RevisionEnvelope.fromCanonicalJson(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Envelope must be a JSON object');
    }
    final result = RevisionEnvelope.fromJson(decoded);
    if (result.canonical != source) {
      throw const FormatException('Envelope JSON is not canonical');
    }
    return result;
  }

  final String entityType;
  final String entityId;
  final List<String> parents;
  final String kind;
  final Map<String, Object?> payload;
  final String authoredAt;
  final String originDeviceId;
  int get protocol => 2;
  // All envelope data is frozen before either cache is evaluated. Retain only
  // the string and digest; callers receive their own mutable UTF-8 buffer.
  late final String _canonical = canonicalJson(toJson());
  late final String _revisionId = sha256
      .convert(utf8.encode(_canonical))
      .toString();
  String get canonical => _canonical;
  Uint8List get canonicalBytes => Uint8List.fromList(utf8.encode(_canonical));
  String get revisionId => _revisionId;

  Map<String, Object?> toJson() => {
    'protocol': protocol,
    'entity_type': entityType,
    'entity_id': entityId,
    'parents': parents.toList(),
    'kind': kind,
    'payload': jsonDecode(jsonEncode(payload)),
    'authored_at': authoredAt,
    'origin_device_id': originDeviceId,
  };
}

Object? _freeze(Object? value) {
  if (value is Map<String, Object?>) {
    return Map<String, Object?>.unmodifiable(
      value.map((key, item) => MapEntry(key, _freeze(item))),
    );
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}

/// A source cell preserves absence versus a present blank independently of the
/// eventual edit operation. Names used in source maps are canonical field names.
enum SourcePresence { missing, blank, value }

final class SourceCell {
  const SourceCell.missing() : presence = SourcePresence.missing, value = null;
  const SourceCell.blank() : presence = SourcePresence.blank, value = null;
  SourceCell.value(Object value)
    : presence = SourcePresence.value,
      value = _freeze(_canonicalCopy(value));
  final SourcePresence presence;
  final Object? value;
  Map<String, Object?> toJson() => {'presence': presence.name, 'value': value};
}

/// Source identity includes only normalized incoming semantics. File paths,
/// row numbers, local current records and resolved canonical IDs have no slots.
final class SourceFingerprint {
  SourceFingerprint._(this.canonical);
  factory SourceFingerprint.create({
    required Map<String, SourceCell> fields,
    required Map<String, Object?> inputIdentity,
    required Map<String, Object?> mappingSemantics,
    required Map<String, Object?> batchDefaults,
    required String captureMode,
  }) {
    if (!const ['standard', 'historical'].contains(captureMode)) {
      throw const FormatException('Unknown capture mode');
    }
    return SourceFingerprint._(
      canonicalJson({
        'version': 1,
        'fields': fields.map((key, cell) => MapEntry(key, cell.toJson())),
        'input_identity': inputIdentity,
        'mapping_semantics': mappingSemantics,
        'batch_defaults': batchDefaults,
        'capture_mode': captureMode,
      }),
    );
  }
  final String canonical;
  int get version => 1;
  String get digest => canonicalSha256(jsonDecode(canonical));
}

enum FieldOperationKind { keep, clear, set }

final class FieldOperation {
  const FieldOperation.keep() : kind = FieldOperationKind.keep, value = null;
  const FieldOperation.clear() : kind = FieldOperationKind.clear, value = null;
  FieldOperation.set(Object value)
    : kind = FieldOperationKind.set,
      value = _freeze(_canonicalCopy(value));
  final FieldOperationKind kind;
  final Object? value;
  Map<String, Object?> toJson() => {'kind': kind.name, 'value': value};
}

enum ImportIntent { modify, newInquiry, importHistorical }

/// Fingerprints explicit user intent, never a merged copy of the current row.
/// Receipt uniqueness additionally requires a persisted confirmation event ID;
/// a fresh event is only created for a new explicit user confirmation.
final class OperationFingerprint {
  OperationFingerprint._(this.canonical);
  factory OperationFingerprint.create({
    required SourceFingerprint source,
    required ImportIntent intent,
    required Map<String, Object?> originalBindings,
    required Map<String, FieldOperation> operations,
    required int confirmedQuantity,
  }) {
    if (confirmedQuantity <= 0) {
      throw const FormatException('Confirmed quantity must be positive');
    }
    return OperationFingerprint._(
      canonicalJson({
        'version': 1,
        'source_fingerprint': source.digest,
        'intent': intent.name,
        'original_bindings': originalBindings,
        'operations': operations.map(
          (key, operation) => MapEntry(key, operation.toJson()),
        ),
        'confirmed_quantity': confirmedQuantity,
      }),
    );
  }
  final String canonical;
  int get version => 1;
  String get digest => canonicalSha256(jsonDecode(canonical));
}

Object? _canonicalCopy(Object? value) => jsonDecode(canonicalJson(value));
