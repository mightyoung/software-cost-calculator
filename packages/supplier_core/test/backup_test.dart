import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_backup'));
  tearDown(() => tmp.deleteSync(recursive: true));

  List<Object?> attachments(Store s) => [
    for (final row in s.db.select('SELECT * FROM attachment ORDER BY id'))
      row.values,
  ];

  test(
    'restore replaces records, history and attachments; safety copy recovers',
    () {
      final a = device('A');
      final sup = a.save('supplier', supplier('原供应商'));
      final prod = a.save('product', product('原始离心泵'));
      a.addAttachment('original.txt', [1, 2, 3]);
      final expected = content(a);
      final expectedAttachments = attachments(a);
      final source = exported(a);
      final sourceBytes = File(source).readAsBytesSync();
      a.save('supplier', supplier('修改供应商'), id: sup);
      a.delete('product', prod);
      a.save('product', product('新增电动机'));
      a.addAttachment('new.txt', [4, 5]);
      final before = content(a);
      final beforeAttachments = attachments(a);
      final connection = a.db;
      final backup = '${tmp.path}/restore-backups/before.siq';
      expect(a.snapshotCounts(source)['product'], 1);
      a.replaceFrom(source, safetyBackupPath: backup);
      expect(identical(a.db, connection), isTrue);
      expect(a.device, 'A');
      expect(content(a), expected);
      expect(attachments(a), expectedAttachments);
      expect(File(source).readAsBytesSync(), sourceBytes);
      expect(a.searchProducts(['原始离心泵']).single.id, prod);
      expect(a.searchProducts(['新增电动机']), isEmpty);
      a.replaceFrom(backup, safetyBackupPath: '${tmp.path}/undo.siq');
      expect(content(a), before);
      expect(attachments(a), beforeAttachments);
      expect(a.searchProducts(['原始离心泵']), isEmpty);
      a.close();
    },
  );

  test(
    'invalid references roll back all replaced tables and search indexes',
    () {
      final a = device('A');
      a.save('product', product('保留离心泵'));
      a.addAttachment('keep.txt', [7]);
      final b = device('B');
      final sup = b.save('supplier', supplier('供应商'));
      final prod = b.save('product', product('损坏离心泵'));
      final pro = b.save('project', project('P1'));
      b.save('quotation', quotation(sup, prod, pro, '100'));
      final source = exported(b);
      final bad = sqlite3.open(source);
      bad.execute('DELETE FROM supplier');
      bad.close();
      final before = content(a);
      final blobs = attachments(a);
      expect(
        () => a.replaceFrom(source, safetyBackupPath: '${tmp.path}/safe.siq'),
        throwsFormatException,
      );
      expect(content(a), before);
      expect(attachments(a), blobs);
      expect(a.searchProducts(['保留离心泵']), hasLength(1));
      expect(a.searchProducts(['损坏离心泵']), isEmpty);
      final recovered = device('R');
      recovered.importFrom('${tmp.path}/safe.siq');
      expect(content(recovered), before);
      expect(attachments(recovered), blobs);
      a.close();
      b.close();
      recovered.close();
    },
  );

  test('restore migrates old snapshot without modifying the source', () {
    final a = device('A');
    a.save('product', product('老版本产品'));
    final expected = content(a);
    final source = exported(a);
    final old = sqlite3.open(source);
    old.execute(
      "UPDATE product SET data=json_remove(data,'\$.unit_conversions')",
    );
    old.execute("UPDATE meta SET value='5' WHERE key='schema_version'");
    old.close();
    final bytes = File(source).readAsBytesSync();
    a.save('product', product('应移除产品'));
    a.replaceFrom(source, safetyBackupPath: '${tmp.path}/before-old.siq');
    expect(content(a), expected);
    expect(File(source).readAsBytesSync(), bytes);
    a.close();
  });

  test('invalid older rows and existing attachments are still checked', () {
    final a = device('A');
    final id = a.save('supplier', supplier('原供应商'));
    a.addAttachment('original.txt', [1, 2, 3]);
    for (final mutation in [
      'UPDATE supplier SET version=0',
      'UPDATE attachment SET size=99',
      "UPDATE change_log SET entity='unknown'",
    ]) {
      final source = exported(a);
      final corrupt = sqlite3.open(source);
      corrupt.execute(mutation);
      corrupt.close();
      a.save('supplier', supplier('更新供应商'), id: id);
      final before = content(a);
      final blobs = attachments(a);
      expect(
        () => a.replaceFrom(source, safetyBackupPath: '$source.safe.siq'),
        throwsFormatException,
      );
      expect(content(a), before);
      expect(attachments(a), blobs);
    }
    a.close();
  });

  test(
    'existing safety copy and active database cannot be restore targets',
    () {
      final a = device('A');
      a.save('supplier', supplier('甲'));
      final source = exported(a);
      final before = content(a);
      expect(
        () => a.replaceFrom(source, safetyBackupPath: source),
        throwsFormatException,
      );
      final live = a.db.select('PRAGMA database_list').first['file'] as String;
      expect(
        () => a.replaceFrom(live, safetyBackupPath: '${tmp.path}/self.siq'),
        throwsFormatException,
      );
      final corrupt = File('${tmp.path}/invalid.siq')
        ..writeAsStringSync('not sqlite');
      expect(
        () => a.replaceFrom(
          corrupt.path,
          safetyBackupPath: '${tmp.path}/invalid-backup.siq',
        ),
        throwsFormatException,
      );
      expect(content(a), before);
      a.close();
    },
  );

  test('one snapshot per day, newest seven kept, each restorable', () {
    final a = device('A');
    a.save('supplier', supplier('甲'));
    final dir = '${tmp.path}/backups';
    final first = a.dailyBackup(dir, now: DateTime(2026, 9, 1));
    expect(first, endsWith('2026-09-01.siq'));
    expect(a.dailyBackup(dir, now: DateTime(2026, 9, 1, 18)), isNull);
    for (var d = 2; d <= 10; d++) {
      a.dailyBackup(dir, now: DateTime(2026, 9, d));
    }
    final names = Directory(
      dir,
    ).listSync().map((f) => f.uri.pathSegments.last).toList()..sort();
    expect(names, hasLength(7));
    expect(names.first, contains('2026-09-04'));
    expect(names.last, contains('2026-09-10'));

    final restored = device('R');
    restored.importFrom('$dir/${names.last}');
    expect(content(restored), content(a));
  });
}
