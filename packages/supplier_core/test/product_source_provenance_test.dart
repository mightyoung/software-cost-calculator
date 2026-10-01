import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  late Store a, b;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('product_provenance');
    a = device('A');
    b = device('B');
  });
  tearDown(() {
    a.close();
    b.close();
    tmp.deleteSync(recursive: true);
  });

  String legacyV11(String path) {
    final db = sqlite3.open(path);
    db.execute(
      "UPDATE product SET data=json_remove(data,'\$.source_attachment_ids')",
    );
    db.execute("UPDATE meta SET value='11' WHERE key='schema_version'");
    db.close();
    return path;
  }

  test(
    'real schema 11 product rows migrate on open without business edits',
    () {
      final id = a.save('product', product('旧库产品'));
      final expected = a.db.select('SELECT * FROM product WHERE id=?', [
        id,
      ]).single;
      final path = legacyV11(exported(a));
      final upgraded = Store.open(path, device: 'legacy-reader');
      try {
        expect(
          upgraded.get('product', id)!.data['source_attachment_ids'],
          isNull,
        );
        expect(
          upgraded.db.select('SELECT * FROM product WHERE id=?', [id]).single,
          expected,
        );
        expect(
          upgraded.db
              .select("SELECT value FROM meta WHERE key='schema_version'")
              .single['value'],
          '$schemaVersion',
        );
        expect(File('$path.pre-v11-migration.siq').existsSync(), isTrue);
      } finally {
        upgraded.close();
      }
    },
  );

  test(
    'schema 11 exchange migrates a private copy and preserves original file',
    () {
      final id = a.save('product', product('旧交换文件产品'));
      final expected = a.db.select('SELECT * FROM product WHERE id=?', [
        id,
      ]).single;
      final path = legacyV11(exported(a));
      final digest = sha256.convert(File(path).readAsBytesSync()).toString();
      b.importFrom(path);
      expect(b.get('product', id)!.data['source_attachment_ids'], isNull);
      expect(
        b.db.select('SELECT * FROM product WHERE id=?', [id]).single,
        expected,
      );
      expect(sha256.convert(File(path).readAsBytesSync()).toString(), digest);
    },
  );

  test(
    'unpriced selected product carries source and parameter evidence only',
    () async {
      final bytes = utf8.encode('产品页面快照：品牌、型号和原始技术参数，没有报价');
      final source = a.addAttachment('source.txt', bytes, mime: 'text/plain');
      final parameterSource = a.addAttachment(
        'datasheet.txt',
        utf8.encode('物理核数8'),
      );
      final unrelated = a.addAttachment('private.txt', [1, 2, 3]);
      final id = a.save('product', {
        ...product('工控机'),
        'source_attachment_ids': [source],
      });
      final param = a.setParam(id, 'cpu.cores', {
        'v': '8',
      }, attachmentId: parameterSource);
      final path = '${tmp.path}/product.siq';
      await a.exportSelection(path, {
        'product': [id],
      });
      b.importFrom(path);
      expect(b.get('product', id)!.data['source_attachment_ids'], [source]);
      expect(
        b.get('product_param', param)!.data['attachment_id'],
        parameterSource,
      );
      expect(b.attachment(source)!.bytes, bytes);
      expect(
        sha256.convert(b.attachment(source)!.bytes!).toString(),
        sha256.convert(bytes).toString(),
      );
      expect(b.attachment(parameterSource), isNotNull);
      expect(b.attachment(unrelated), isNull);
      expect(b.db.select('SELECT id FROM quotation'), isEmpty);
      expect(b.db.select('SELECT id FROM attachment'), hasLength(2));
    },
  );

  test(
    'referenced product brings source without unrelated quote history',
    () async {
      final source = a.addAttachment('source.txt', [4, 5]);
      final private = a.addAttachment('private.txt', [6, 7]);
      final id = a.save('product', {
        ...product('产品'),
        'source_attachment_ids': [source],
      });
      final supplierId = a.save('supplier', supplier('供应商'));
      final projectId = a.save('project', project('chosen'));
      final otherProject = a.save('project', project('private'));
      a.save('project_item', item(projectId, 'material', productId: id));
      final quote = a.save('quotation', {
        ...quotation(supplierId, id, otherProject, '42'),
        'attachment_ids': [private],
      });
      final path = '${tmp.path}/project.siq';
      await a.exportSelection(path, {
        'project': [projectId],
      });
      b.importFrom(path);
      expect(b.attachment(source), isNotNull);
      expect(b.attachment(private), isNull);
      expect(b.get('quotation', quote), isNull);
      expect(b.get('project', otherProject), isNull);
    },
  );

  test(
    'legacy product payload remains valid; source IDs are bounded UUIDs',
    () {
      final legacy = product('legacy');
      expect(
        Product.fromJson(legacy).toJson()['source_attachment_ids'],
        isNull,
      );
      expect(a.save('product', legacy), isNotEmpty);
      for (final bad in [
        42,
        ['not-a-uuid'],
        List.filled(9, newUuid()),
      ]) {
        expect(
          () => a.save('product', {...legacy, 'source_attachment_ids': bad}),
          throwsA(isA<FormatException>()),
        );
      }
      expect(
        () => a.save('product', {
          ...legacy,
          'source_attachment_ids': [newUuid()],
        }),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test(
    'exchange rejects missing product source bytes and rolls back',
    () async {
      final source = a.addAttachment('source.txt', [8, 9]);
      final id = a.save('product', {
        ...product('产品'),
        'source_attachment_ids': [source],
      });
      final path = '${tmp.path}/broken.siq';
      await a.exportSelection(path, {
        'product': [id],
      });
      final file = sqlite3.open(path);
      file.execute('DELETE FROM attachment');
      file.close();
      expect(() => b.importFrom(path), throwsA(isA<FormatException>()));
      expect(b.get('product', id), isNull);
      final retained = b.save('product', product('保留的本地物料'));
      expect(
        () => b.replaceFrom(path, safetyBackupPath: '${tmp.path}/safety.siq'),
        throwsA(isA<FormatException>()),
      );
      expect(b.get('product', id), isNull);
      expect(b.get('product', retained), isNotNull);
    },
  );
}
