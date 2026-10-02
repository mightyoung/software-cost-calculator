import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:supplier_core/src/domain/canonical.dart';
import 'package:supplier_core/src/domain/revision.dart';
import 'package:test/test.dart';

Map<String, Object?> envelope() => {
  'protocol': 2,
  'entity_type': 'supplier',
  'entity_id': '11111111-1111-4111-8111-111111111111',
  'parents': <String>['a' * 64],
  'kind': 'put',
  'payload': <String, Object?>{
    'name': '供应商 é 😀',
    'aliases': <String>['别名'],
    'categories': <String>['设备'],
    'address': null,
    'notes': 'line\n"quoted"',
  },
  'authored_at': '2026-09-16T08:00:00.000Z',
  'origin_device_id': '22222222-2222-4222-8222-222222222222',
};

void main() {
  test('cached identity exactly matches canonical JSON, UTF-8 and SHA256', () {
    final input = envelope();
    final expected = canonicalJson(input);
    final expectedBytes = utf8.encode(expected);
    final revision = RevisionEnvelope.fromJson(input);
    expect(revision.canonical, expected);
    expect(revision.canonicalBytes, expectedBytes);
    expect(revision.revisionId, sha256.convert(expectedBytes).toString());
    expect(identical(revision.canonical, revision.canonical), isTrue);
    expect(identical(revision.revisionId, revision.revisionId), isTrue);
    final parsed = RevisionEnvelope.fromCanonicalJson(expected);
    expect(parsed.canonical, expected);
    expect(parsed.revisionId, revision.revisionId);
    final changed = RevisionEnvelope.fromJson({
      ...input,
      'authored_at': '2026-09-17T08:00:00.000Z',
    });
    expect(changed.revisionId, isNot(revision.revisionId));
  });

  for (final readDigestFirst in [false, true]) {
    test(
      'identity survives all mutable copies (digest first: $readDigestFirst)',
      () {
        final input = envelope();
        final expected = canonicalJson(input);
        final revision = RevisionEnvelope.fromJson(input);
        if (readDigestFirst) revision.revisionId;
        (input['parents'] as List<String>).clear();
        final payload = input['payload'] as Map<String, Object?>;
        (payload['aliases'] as List<String>).add('changed');
        (payload['categories'] as List<String>).clear();
        payload['name'] = 'changed';
        input['authored_at'] = 'changed';
        final copy = revision.toJson();
        (copy['parents'] as List).clear();
        final copyPayload = copy['payload'] as Map;
        (copyPayload['aliases'] as List).clear();
        (copyPayload['categories'] as List).add('changed');
        copyPayload['name'] = 'changed';
        final bytes = revision.canonicalBytes;
        bytes.fillRange(0, bytes.length, 0);
        expect(revision.canonical, expected);
        expect(revision.canonicalBytes, utf8.encode(expected));
        expect(
          revision.revisionId,
          sha256.convert(utf8.encode(expected)).toString(),
        );
        expect(canonicalJson(revision.toJson()), expected);
        expect(() => revision.parents.add('b' * 64), throwsUnsupportedError);
        expect(
          () => revision.payload['name'] = 'changed',
          throwsUnsupportedError,
        );
        expect(
          () => (revision.payload['aliases'] as List).clear(),
          throwsUnsupportedError,
        );
        expect(
          () => (revision.payload['categories'] as List).clear(),
          throwsUnsupportedError,
        );
      },
    );
  }

  test('cached construction still rejects noncanonical persisted input', () {
    final canonical = canonicalJson(envelope());
    for (final invalid in [
      '$canonical\n',
      canonical.replaceFirst('"protocol":2', '"protocol":2.0'),
      canonical.replaceFirst('供应商', r'\u4f9b\u5e94\u5546'),
    ]) {
      expect(
        () => RevisionEnvelope.fromCanonicalJson(invalid),
        throwsFormatException,
      );
    }
    final input = envelope();
    (input['payload'] as Map)['name'] = '  padded  ';
    expect(() => RevisionEnvelope.fromJson(input), throwsFormatException);
  });
}
