// Shared VM/JavaScript numeric contract: deliberately no dart:io imports.
import 'package:supplier_core/src/domain/canonical.dart';
import 'package:supplier_core/src/domain/revision.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Unicode and object ordering stay canonical across VM and JavaScript',
    () {
      expect(
        canonicalJson({'\uE000': 1, '😀': 2, 'a': '\n'}),
        '{"a":"\\n","😀":2,"\uE000":1}',
      );
      for (final invalid in ['\uD800', '\uDC00']) {
        expect(() => canonicalJson(invalid), throwsFormatException);
      }
    },
  );
  test(
    'safe integral inputs canonicalize identically on VM and JavaScript',
    () {
      expect(
        canonicalJson([1, 1.0, -0.0, 9007199254740991.0]),
        '[1,1,0,9007199254740991]',
      );
      for (final value in [
        1.5,
        double.nan,
        double.infinity,
        double.negativeInfinity,
        9007199254740992,
        -9007199254740992,
      ]) {
        expect(() => canonicalJson(value), throwsFormatException);
      }
    },
  );
  test(
    'protocol numeric input normalizes but wire spelling stays canonical',
    () {
      final data = <String, Object?>{
        'protocol': 2.0,
        'entity_type': 'supplier',
        'entity_id': '11111111-1111-4111-8111-111111111111',
        'parents': <String>[],
        'kind': 'delete',
        'payload': <String, Object?>{},
        'authored_at': '2026-09-16T08:00:00.000Z',
        'origin_device_id': '22222222-2222-4222-8222-222222222222',
      };
      final revision = RevisionEnvelope.fromJson(data);
      expect(revision.protocol, 2);
      expect(revision.canonical, contains('"protocol":2'));
      expect(
        () => RevisionEnvelope.fromCanonicalJson(
          revision.canonical.replaceFirst('"protocol":2', '"protocol":2.0'),
        ),
        throwsFormatException,
      );
      expect(
        () => RevisionEnvelope.fromJson({...data, 'protocol': 2.5}),
        throwsFormatException,
      );
    },
  );
}
