import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('crypto-security-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'oversized encrypted input is rejected before reading or deriving a key',
    () async {
      final input = File('${tmp.path}/oversized.siq');
      final file = input.openSync(mode: FileMode.write);
      file.writeStringSync('SIQE1\n');
      file.truncateSync(maxEncryptedExchangeBytes + 1);
      file.closeSync();
      final output = Directory('${tmp.path}/decrypted');
      await expectLater(
        decryptExchange(input.path, 'pw', output),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'limit',
            contains('128 MiB'),
          ),
        ),
      );
      expect(output.existsSync(), isFalse);
      await expectLater(
        encryptFile(input.path, '${tmp.path}/out.siq', 'pw'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'limit',
            contains('128 MiB'),
          ),
        ),
      );
      expect(File('${tmp.path}/out.siq.part').existsSync(), isFalse);
    },
  );

  for (final selected in [false, true]) {
    test(
      'failed ${selected ? 'selection' : 'snapshot'} export removes staging',
      () async {
        final s = device('A');
        addTearDown(s.close);
        final scratch = Directory('${tmp.path}/scratch')..createSync();
        // Force a failure before encryption, while a private directory exists.
        s.db.execute('DROP TABLE change_log');
        await IOOverrides.runZoned(() async {
          final future = selected
              ? s.exportSelection('${tmp.path}/out.siq', {}, passphrase: 'pw')
              : s.exportEncryptedTo('${tmp.path}/missing/out.siq', 'pw');
          await expectLater(future, throwsA(anything));
        }, getSystemTempDirectory: () => scratch);
        expect(scratch.listSync(), isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
    test(
      'encrypted ${selected ? 'selection' : 'snapshot'} never stages beside output',
      () async {
        final s = device('A');
        addTearDown(s.close);
        final id = s.save('supplier', supplier('Private supplier'));
        final shared = Directory('${tmp.path}/shared')..createSync();
        final path = '${shared.path}/out.siq';
        final future = selected
            ? s.exportSelection(path, {
                'supplier': [id],
              }, passphrase: 'pw')
            : s.exportEncryptedTo(path, 'pw');
        // Encryption yields during isolate work: plaintext used to be visible here.
        expect(shared.listSync(), isEmpty);
        await future;
        expect(shared.listSync().map((f) => f.path), [path]);
        expect(isEncryptedExchange(path), isTrue);
        final plain = await decryptExchange(path, 'pw', tmp);
        final other = device('B');
        addTearDown(other.close);
        other.importFrom(plain);
        expect(other.get('supplier', id), isNotNull);
      },
    );
  }

  test(
    'encrypted sync rejects plain source without marking seen; manual import works',
    () async {
      final a = device('A'), b = device('B');
      addTearDown(a.close);
      addTearDown(b.close);
      final id = a.save('supplier', supplier('Legacy'));
      final shared = Directory('${tmp.path}/shared')..createSync();
      final path = '${shared.path}/legacy.siq';
      a.exportTo(path);
      final result = await b.syncWithFolder(
        shared.path,
        ownName: 'B.siq',
        seen: {},
        passphrase: 'pw',
      );
      expect(result.failed.keys, contains('legacy.siq'));
      expect(result.seen, isNot(contains('legacy.siq')));
      expect(b.get('supplier', id), isNull);
      b.importFrom(path);
      expect(b.get('supplier', id), isNotNull);
    },
  );
}
