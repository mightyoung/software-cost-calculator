import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// Rewrites a current file into what version 1 of the app produced:
/// suppliers and products without `merged_into`.
String downgradeToV1(String path) {
  final db = sqlite3.open(path);
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
    upgraded.close();
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
