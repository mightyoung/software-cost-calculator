import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_crypto'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'encrypted exchange file: right passphrase imports, wrong one fails',
    () async {
      final a = device('A');
      a.save('supplier', supplier('甲泵业'));
      final path = '${tmp.path}/a.siq';
      await a.exportEncryptedTo(path, '口令-2026');
      expect(isEncryptedExchange(path), isTrue);
      expect(isEncryptedExchange(exported(a)), isFalse);
      expect(
        File(path).readAsStringSync(encoding: const Latin1Codec()),
        isNot(contains('supplier')),
      );

      final b = device('B');
      final plain = await decryptExchange(path, '口令-2026', tmp);
      b.importFrom(plain);
      expect(content(b), content(a));

      await expectLater(
        decryptExchange(path, 'wrong', tmp),
        throwsA(isA<FormatException>()),
      );
      final bytes = File(path).readAsBytesSync();
      bytes[bytes.length - 20] ^= 1;
      File('${tmp.path}/t.siq').writeAsBytesSync(bytes);
      await expectLater(
        decryptExchange('${tmp.path}/t.siq', '口令-2026', tmp),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('shared folder with a passphrase', () async {
    final dir = Directory('${tmp.path}/shared')..createSync();
    final a = device('A'), b = device('B'), c = device('C');
    final sa = a.save('supplier', supplier('甲'));
    await a.syncWithFolder(
      dir.path,
      ownName: 'A.siq',
      seen: {},
      passphrase: 'pw',
    );
    expect(isEncryptedExchange('${dir.path}/A.siq'), isTrue);
    final rb = await b.syncWithFolder(
      dir.path,
      ownName: 'B.siq',
      seen: {},
      passphrase: 'pw',
    );
    expect(rb.imported, ['A.siq']);
    expect(b.get('supplier', sa), isNotNull);
    final rc = await c.syncWithFolder(dir.path, ownName: 'C.siq', seen: {});
    expect(rc.failed.keys, containsAll(['A.siq', 'B.siq']));
    expect(rc.failed['A.siq'], contains('口令'));
  });
}
