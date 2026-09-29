import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:supplier_core/src/search_index.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// Rewrites a current file into what version 1 of the app produced:
/// suppliers and products without `merged_into`.
String downgradeToV1(String path) {
  final db = sqlite3.open(path);
  dropSearchIndex(db); // version 1 had none
  for (final type in ['supplier', 'product']) {
    db.execute("UPDATE $type SET data = json_remove(data, '\$.merged_into')");
  }
  db.execute("UPDATE meta SET value = '1' WHERE key = 'schema_version'");
  db.close();
  return path;
}

String metaVersion(String path) {
  final db = sqlite3.open(path);
  final v =
      db.select("SELECT value FROM meta WHERE key='schema_version'").first[0]
          as String;
  db.close();
  return v;
}

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_migrate'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Store seeded() {
    final a = device('A');
    final sup = a.save('supplier', supplier('甲泵业'));
    final prod = a.save('product', product('离心泵'));
    final pro = a.save('project', project('P1'));
    a.save('quotation', quotation(sup, prod, pro, '3200'));
    a.delete('product', a.save('product', product('废弃物料')));
    return a;
  }

  test('an older database is upgraded in place without new versions', () {
    final a = seeded();
    final current = content(a);
    final old = downgradeToV1(exported(a));
    expect(metaVersion(old), '1');

    final upgraded = Store.open(old, device: 'A');
    expect(metaVersion(old), '$schemaVersion');
    expect(content(upgraded), current, reason: 'same data, same versions');
    final backup = File('$old.pre-v1-migration.siq');
    expect(backup.existsSync(), isTrue);
    expect(metaVersion(backup.path), '1');
    final restored = device('C');
    restored.importFrom(backup.path);
    expect(
      content(restored),
      current,
      reason: 'backup restores pre-upgrade data',
    );
    upgraded.close();
  });

  test('schema 10 requirements move from notes into their own field', () {
    expect(splitLegacyRequirement('要求：DN100，远传；清单单位：套'), (
      'DN100，远传',
      '清单单位：套',
    ));
    expect(splitLegacyRequirement('要求：IP65；数量待确认，清单原文：若干'), (
      'IP65',
      '数量待确认，清单原文：若干',
    ));
    expect(splitLegacyRequirement('要求：A；B'), ('A；B', null));
    expect(splitLegacyRequirement('现场自提'), (null, '现场自提'));

    final a = device('A');
    final pro = a.save('project', project('P1'));
    final line = a.save('project_item', {
      ...item(pro, 'material', name: '流量计'),
      'requirement': 'DN100，远传 4-20mA',
      'notes': '清单单位：套',
    });
    final path = exported(a);
    final db = sqlite3.open(path);
    db.execute(
      "UPDATE project_item SET data = json_set(json_remove(data, '\$.requirement'), "
      "'\$.notes', '要求：DN100，远传 4-20mA；清单单位：套')",
    );
    db.execute("UPDATE meta SET value = '10' WHERE key = 'schema_version'");
    db.close();
    final b = device('B');
    b.importFrom(path);
    final d = b.get('project_item', line)!.data;
    expect(d['requirement'], 'DN100，远传 4-20mA');
    expect(d['notes'], '清单单位：套');
  });

  test('an older exchange file imports; the file itself is untouched', () {
    final a = seeded();
    final old = downgradeToV1(exported(a));
    final b = device('B');
    b.importFrom(old);
    expect(metaVersion(old), '1');
    final c = device('C');
    c.importFrom(exported(a));
    expect(content(b), content(c));
  });

  test('failed old-file migration cleans its temporary copy', () {
    final a = seeded();
    final old = downgradeToV1(exported(a));
    final file = sqlite3.open(old);
    file.execute(
      "UPDATE product SET data=json_set(data, '\$.unknown_field', 1)",
    );
    file.close();
    final originalBytes = File(old).readAsBytesSync();
    final scratch = Directory('${tmp.path}/migration-temp')..createSync();
    final b = device('B');
    IOOverrides.runZoned(() {
      expect(() => b.importFrom(old), throwsFormatException);
      expect(scratch.listSync(), isEmpty);
    }, getSystemTempDirectory: () => scratch);
    expect(File(old).readAsBytesSync(), originalBytes);
  });

  test('a failed pre-migration snapshot leaves the old database unchanged', () {
    final a = seeded();
    final old = downgradeToV1(exported(a));
    final beforeDb = sqlite3.open(old, mode: OpenMode.readOnly);
    final before = [
      for (final type in entityTypes)
        for (final row in beforeDb.select('SELECT * FROM $type ORDER BY id'))
          [type, ...row.values],
    ];
    beforeDb.close();
    Directory('$old.pre-v1-migration.siq').createSync();

    expect(() => Store.open(old, device: 'B'), throwsException);
    expect(metaVersion(old), '1');
    final afterDb = sqlite3.open(old, mode: OpenMode.readOnly);
    final after = [
      for (final type in entityTypes)
        for (final row in afterDb.select('SELECT * FROM $type ORDER BY id'))
          [type, ...row.values],
    ];
    afterDb.close();
    expect(after, before);
  });

  test('files and databases from a newer version are refused', () {
    final a = seeded();
    final newer = exported(a);
    final db = sqlite3.open(newer);
    db.execute("UPDATE meta SET value = '99' WHERE key = 'schema_version'");
    db.close();
    final b = device('B');
    expect(
      () => b.importFrom(newer),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('newer version'),
        ),
      ),
    );
    expect(() => Store.open(newer, device: 'X'), throwsStateError);
  });
}
