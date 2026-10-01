import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  test(
    'full export removes only private assistant state from the copy',
    () async {
      tmp = Directory.systemTemp.createTempSync('assistant_exchange_privacy');
      final store = device('A');
      addTearDown(() {
        store.close();
        tmp.deleteSync(recursive: true);
      });
      const privateKeys = [
        'assistant_web_sources:session',
        'assistant_procurement:session',
        'assistant_action:session',
        'assistant_procurement_receipt:session',
        'ai_applied:session',
      ];
      const retainedKeys = [
        'assistantXwebXsources:session',
        'assistant_procurement_receipt_extra:session',
        'assistant_action',
        'sentinel',
      ];
      for (final key in [...privateKeys, ...retainedKeys]) {
        store.db.execute('INSERT INTO meta(key,value) VALUES (?,?)', [
          key,
          jsonEncode({
            'requestText': privateKeys.contains(key)
                ? 'PRIVATE_CANARY_${privateKeys.indexOf(key)}_END'
                : 'retained sentinel',
            'candidate': '尚未审核',
          }),
        ]);
      }
      final before = store.db.select('SELECT key,value FROM meta ORDER BY key');
      final bytes = utf8.encode('已审核的产品来源');
      final attachment = store.addAttachment('source.txt', bytes);
      final productId = store.save('product', {
        ...product('已审核产品'),
        'source_attachment_ids': [attachment],
      });
      final full = '${tmp.path}/full.siq';
      store.exportTo(full);
      void noPrivateBytes(String path) {
        final fileBytes = latin1.decode(File(path).readAsBytesSync());
        for (var i = 0; i < privateKeys.length; i++) {
          expect(fileBytes, isNot(contains('PRIVATE_CANARY_${i}_END')));
        }
      }

      noPrivateBytes(full);
      final copy = sqlite3.open(full);
      try {
        final keys = copy
            .select('SELECT key FROM meta')
            .map((row) => row['key'])
            .toSet();
        expect(keys.intersection(privateKeys.toSet()), isEmpty);
        expect(keys, containsAll(retainedKeys));
        expect(
          copy.select('SELECT data FROM attachment WHERE id=?', [
            attachment,
          ]).single['data'],
          bytes,
        );
        final payload =
            jsonDecode(
                  copy.select('SELECT data FROM product WHERE id=?', [
                        productId,
                      ]).single['data']
                      as String,
                )
                as Map;
        expect(payload['source_attachment_ids'], [attachment]);
      } finally {
        copy.close();
      }
      expect(
        store.db.select('SELECT key,value FROM meta ORDER BY key'),
        before,
      );
      final encrypted = '${tmp.path}/encrypted.siq';
      await store.exportEncryptedTo(encrypted, 'test-private-state-2026');
      final decrypted = await decryptExchange(
        encrypted,
        'test-private-state-2026',
        tmp,
      );
      noPrivateBytes(decrypted);
      final decryptedStore = Store.open(decrypted, device: 'decrypted-reader');
      try {
        expect(decryptedStore.attachment(attachment)!.bytes, bytes);
        expect(
          decryptedStore
              .get('product', productId)!
              .data['source_attachment_ids'],
          [attachment],
        );
        final keys = decryptedStore.db
            .select('SELECT key FROM meta')
            .map((row) => row['key'])
            .toSet();
        expect(keys.intersection(privateKeys.toSet()), isEmpty);
        expect(keys, containsAll(retainedKeys));
      } finally {
        decryptedStore.close();
      }
      expect(
        store.db.select('SELECT key,value FROM meta ORDER BY key'),
        before,
      );
      final selection = '${tmp.path}/selection.siq';
      await store.exportSelection(selection, {
        'product': [productId],
      });
      final selected = Store.open(selection, device: 'selected-reader');
      try {
        expect(
          selected.get('product', productId)!.data['source_attachment_ids'],
          [attachment],
        );
        expect(selected.attachment(attachment)!.bytes, bytes);
        expect(
          selected.db.select(
            "SELECT key FROM meta WHERE key GLOB 'assistant_*'",
          ),
          isEmpty,
        );
      } finally {
        selected.close();
      }
    },
  );
}
