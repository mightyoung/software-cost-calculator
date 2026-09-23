import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/src/domain/canonical.dart';
import 'package:supplier_core/src/domain/revision.dart';
import 'package:test/test.dart';

const entityId = '11111111-1111-4111-8111-111111111111';
const deviceId = '22222222-2222-4222-8222-222222222222';
Map<String, Object?> supplier() => {
  'name': '供应商 é',
  'aliases': <String>[],
  'address': null,
  'categories': <String>[],
  'notes': 'line\n"quoted"',
};
Map<String, Object?> envelope() => {
  'protocol': 2,
  'entity_type': 'supplier',
  'entity_id': entityId,
  'parents': <String>[],
  'kind': 'put',
  'payload': supplier(),
  'authored_at': '2026-09-16T08:00:00.000Z',
  'origin_device_id': deviceId,
};

void main() {
  group('restricted JCS', () {
    test('UTF-16 key ordering and JSON escaping', () {
      expect(
        canonicalJson({'\uE000': 1, '😀': 2, 'a': '\b\t\n\f\r"\\\u0000'}),
        '{"a":"\\b\\t\\n\\f\\r\\"\\\\\\u0000","😀":2,"\uE000":1}',
      );
      expect(
        canonicalJson([null, true, false, -9007199254740991, 9007199254740991]),
        '[null,true,false,-9007199254740991,9007199254740991]',
      );
    });
    test('rejects fractions, unsafe integers, invalid strings and keys', () {
      for (final value in <Object?>[
        1.5,
        double.nan,
        9007199254740992,
        -9007199254740992,
        '\uD800',
        '\uDC00',
        {'\uD800': 1},
        {1: 'a'},
        Object(),
      ]) {
        expect(
          () => canonicalJson(value),
          throwsFormatException,
          reason: '$value',
        );
      }
    });
  });
  group('versioned source and operation fingerprints', () {
    SourceFingerprint source(
      SourceCell cell, {
      String supplier = entityId,
      String mode = 'historical',
      Map<String, Object?> defaults = const {},
    }) => SourceFingerprint.create(
      fields: {'notes': cell},
      inputIdentity: {'supplier': supplier},
      mappingSemantics: {'notes': 'notes'},
      batchDefaults: defaults,
      captureMode: mode,
    );
    OperationFingerprint operation(
      SourceFingerprint src,
      FieldOperation field, {
      ImportIntent intent = ImportIntent.modify,
      int quantity = 1,
    }) => OperationFingerprint.create(
      source: src,
      intent: intent,
      originalBindings: {'supplier_id': entityId},
      operations: {'notes': field},
      confirmedQuantity: quantity,
    );
    test('missing blank and value source states remain distinct', () {
      expect({
        source(const SourceCell.missing()).digest,
        source(const SourceCell.blank()).digest,
        source(SourceCell.value('A')).digest,
      }, hasLength(3));
      final original = source(const SourceCell.blank());
      expect(original.version, 1);
      expect(original.digest, source(const SourceCell.blank()).digest);
      expect(
        original.digest,
        isNot(source(const SourceCell.blank(), supplier: deviceId).digest),
      );
      expect(
        original.digest,
        isNot(source(const SourceCell.blank(), mode: 'standard').digest),
      );
      expect(
        original.digest,
        isNot(
          source(const SourceCell.blank(), defaults: {'notes': 'A'}).digest,
        ),
      );
    });
    test('keep clear set intent and quantity define operation identity', () {
      final src = source(const SourceCell.blank());
      final keep = operation(src, const FieldOperation.keep());
      expect(keep.version, 1);
      expect({
        keep.digest,
        operation(src, const FieldOperation.clear()).digest,
        operation(src, FieldOperation.set('A')).digest,
        operation(
          src,
          const FieldOperation.keep(),
          intent: ImportIntent.newInquiry,
        ).digest,
        operation(src, const FieldOperation.keep(), quantity: 2).digest,
      }, hasLength(5));
      expect(
        keep.digest,
        operation(
          source(const SourceCell.blank()),
          const FieldOperation.keep(),
        ).digest,
      );
      expect(
        () => operation(src, const FieldOperation.keep(), quantity: 0),
        throwsFormatException,
      );
      expect(() => SourceCell.value(1.5), throwsFormatException);
    });
  });
  test('independent quotation date instant and historical golden vectors', () {
    final vectors =
        jsonDecode(
              File(
                'test/fixtures/v2/quotation-vectors.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    for (final entry in vectors.entries) {
      final vector = entry.value as Map<String, dynamic>;
      final revision = RevisionEnvelope.fromJson(
        vector['value'] as Map<String, dynamic>,
      );
      expect(revision.canonical, vector['canonical'], reason: entry.key);
      expect(revision.revisionId, vector['sha256'], reason: entry.key);
    }
  });
  test('independent source and operation golden vectors', () {
    final vectors =
        jsonDecode(
              File(
                'test/fixtures/v2/fingerprint-vectors.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final sourceVector = vectors['source'] as Map<String, dynamic>;
    final sourceData = sourceVector['value'] as Map<String, dynamic>;
    final source = SourceFingerprint.create(
      fields: {
        'notes': const SourceCell.blank(),
        'project_number': SourceCell.value('000123-A'),
        'inquiry_location': const SourceCell.missing(),
      },
      inputIdentity: sourceData['input_identity'] as Map<String, dynamic>,
      mappingSemantics: sourceData['mapping_semantics'] as Map<String, dynamic>,
      batchDefaults: sourceData['batch_defaults'] as Map<String, dynamic>,
      captureMode: 'historical',
    );
    expect(source.canonical, sourceVector['canonical']);
    expect(source.digest, sourceVector['sha256']);
    final operationVector = vectors['operation'] as Map<String, dynamic>;
    final operation = OperationFingerprint.create(
      source: source,
      intent: ImportIntent.modify,
      originalBindings: {'supplier_id': entityId},
      operations: {
        'notes': const FieldOperation.keep(),
        'inquiry_location': const FieldOperation.clear(),
        'project_number': FieldOperation.set('000123-A'),
      },
      confirmedQuantity: 1,
    );
    expect(operation.canonical, operationVector['canonical']);
    expect(operation.digest, operationVector['sha256']);
  });
  group('protocol 2 envelope', () {
    test('24000 UTF-16 units accepted and 24001 rejected', () {
      final input = envelope()
        ..['parents'] = List.generate(
          340,
          (i) => i.toRadixString(16).padLeft(64, '0'),
        );
      final payload = input['payload'] as Map<String, Object?>;
      payload['notes'] = 'x';
      final padding = 24000 - canonicalJson(input).length;
      payload['notes'] = 'x' * (padding + 1);
      expect(canonicalJson(input).length, 24000);
      expect(RevisionEnvelope.fromJson(input).canonical.length, 24000);
      payload['notes'] = 'x' * (padding + 2);
      expect(canonicalJson(input).length, 24001);
      expect(() => RevisionEnvelope.fromJson(input), throwsFormatException);
    });

    test('matches independently frozen Python canonical bytes and SHA256', () {
      final fixture =
          jsonDecode(
                File('test/fixtures/v2/supplier-root.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final revision = RevisionEnvelope.fromJson(envelope());
      expect(revision.canonical, fixture['canonical']);
      expect(revision.revisionId, fixture['sha256']);
      expect(utf8.decode(revision.canonicalBytes), fixture['canonical']);
      expect(
        RevisionEnvelope.fromCanonicalJson(revision.canonical).revisionId,
        revision.revisionId,
      );
    });
    test(
      'create sorts parents; persisted input rejects unsorted and duplicates',
      () {
        final a = 'a' * 64;
        final b = 'b' * 64;
        final revision = RevisionEnvelope.create(
          entityType: 'supplier',
          entityId: entityId,
          parents: [b, a, a],
          kind: 'put',
          payload: supplier(),
          authoredAt: '2026-09-16T08:00:00.000Z',
          originDeviceId: deviceId,
        );
        expect(revision.parents, [a, b]);
        for (final parents in [
          [b, a],
          [a, a],
          ['bad'],
        ]) {
          expect(
            () => RevisionEnvelope.fromJson(envelope()..['parents'] = parents),
            throwsFormatException,
          );
        }
      },
    );
    test('rejects missing unknown and incorrectly typed envelope keys', () {
      expect(
        () => RevisionEnvelope.fromJson(envelope()..remove('payload')),
        throwsFormatException,
      );
      expect(
        () => RevisionEnvelope.fromJson(envelope()..['extra'] = null),
        throwsFormatException,
      );
      for (final entry in {
        'protocol': 2.5,
        'entity_type': 'other',
        'entity_id': 'wrong',
        'parents': null,
        'kind': 'patch',
        'payload': [],
        'authored_at': 1,
        'origin_device_id': 'wrong',
      }.entries) {
        expect(
          () =>
              RevisionEnvelope.fromJson(envelope()..[entry.key] = entry.value),
          throwsFormatException,
        );
      }
    });
    test('rejects noncanonical and invalid dates and normalized payloads', () {
      for (final date in [
        '2026-02-30T08:00:00.000Z',
        '2026-09-16T08:00:00Z',
        '2026-09-16T08:00:00.000+00:00',
        '2026-09-16T08:00:60.000Z',
      ]) {
        expect(
          () => RevisionEnvelope.fromJson(envelope()..['authored_at'] = date),
          throwsFormatException,
        );
      }
      expect(
        () => RevisionEnvelope.fromJson(
          envelope()..['payload'] = (supplier()..['name'] = ' e\u0301 '),
        ),
        throwsFormatException,
      );
      expect(
        () => RevisionEnvelope.fromJson(
          envelope()..['payload'] = (supplier()..['name'] = '\uD800'),
        ),
        throwsFormatException,
      );
      expect(
        () =>
            RevisionEnvelope.fromCanonicalJson(' ${canonicalJson(envelope())}'),
        throwsFormatException,
      );
    });
    test('delete empty object and redirect exact target shape', () {
      expect(
        RevisionEnvelope.fromJson(
          envelope()
            ..['kind'] = 'delete'
            ..['payload'] = <String, Object?>{},
        ).kind,
        'delete',
      );
      expect(
        () => RevisionEnvelope.fromJson(
          envelope()
            ..['kind'] = 'delete'
            ..['payload'] = null,
        ),
        throwsFormatException,
      );
      expect(
        RevisionEnvelope.fromJson(
          envelope()
            ..['kind'] = 'redirect'
            ..['payload'] = {'target_id': deviceId},
        ).kind,
        'redirect',
      );
      for (final payload in [
        {'target_id': entityId},
        {'target_id': 'wrong'},
        {'target_id': deviceId, 'extra': null},
      ]) {
        expect(
          () => RevisionEnvelope.fromJson(
            envelope()
              ..['kind'] = 'redirect'
              ..['payload'] = payload,
          ),
          throwsFormatException,
        );
      }
    });
    test('owns immutable nested payload and detached serialization', () {
      final input = envelope();
      final revision = RevisionEnvelope.fromJson(input);
      (input['payload'] as Map)['name'] = 'changed';
      expect(revision.payload['name'], '供应商 é');
      expect(
        () => revision.payload['name'] = 'changed',
        throwsUnsupportedError,
      );
      expect(
        () => (revision.payload['aliases'] as List).add('changed'),
        throwsUnsupportedError,
      );
      expect(() => revision.parents.add('changed'), throwsUnsupportedError);
      final serialized = revision.toJson();
      (serialized['payload'] as Map)['name'] = 'changed';
      expect(revision.payload['name'], '供应商 é');
    });
  });
}
