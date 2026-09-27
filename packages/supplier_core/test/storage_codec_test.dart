import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:supplier_core/src/storage_codec.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_sparse'));
  tearDown(() => tmp.deleteSync(recursive: true));

  (Store, String) seeded() {
    final s = device('A');
    addTearDown(s.close);
    final supplierId = s.save('supplier', supplier('甲'));
    final productId = s.save('product', product('泵'));
    final projectId = s.save('project', project('P1'));
    return (
      s,
      s.save('quotation', quotation(supplierId, productId, projectId, '2')),
    );
  }

  String v4File(Store store) {
    final path = exported(store);
    final db = sqlite3.open(path);
    try {
      for (final row in db.select('SELECT id, data FROM quotation')) {
        db.execute('UPDATE quotation SET data=? WHERE id=?', [
          jsonEncode(decodeStoredPayload('quotation', row['data'] as String)),
          row['id'],
        ]);
      }
      db.execute("UPDATE meta SET value='4' WHERE key='schema_version'");
    } finally {
      db.close();
    }
    return path;
  }

  test(
    'quotation storage is sparse while domain and nested maps stay dense',
    () {
      final dense = {
        ...quotation(newUuid(), newUuid(), newUuid(), '2'),
        'contact_snapshot': {
          'name': '张三',
          'phone': '123',
          'wechat': null,
          'email': null,
        },
        'includes': <String>[],
      };
      final encoded = encodeStoredPayload('quotation', dense);
      final sparse = jsonDecode(encoded) as Map<String, Object?>;
      expect(sparse.containsKey('notes'), isFalse);
      expect(sparse['includes'], isEmpty, reason: 'empty arrays are not null');
      expect((sparse['contact_snapshot'] as Map).containsKey('email'), isTrue);
      expect(decodeStoredPayload('quotation', encoded), dense);
      expect(
        sparse.keys,
        Quotation.fields.where((field) => dense[field] != null),
      );
      expect(
        encodeStoredPayload('supplier', supplier('甲')),
        jsonEncode(supplier('甲')),
      );
      expect(() => Quotation.fromJson(sparse), throwsFormatException);
      expect(
        () => encodeStoredPayload('quotation', sparse),
        throwsFormatException,
      );
      expect(
        () => decodeStoredPayload('quotation', '{"unexpected":null}'),
        throwsFormatException,
      );
      expect(
        () => decodeStoredPayload('quotation', '[]'),
        throwsFormatException,
      );
      expect(
        () => decodeStoredPayload(
          'quotation',
          jsonEncode({...sparse}..remove('price')),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'save and get retain explicit nulls and clearing requires confirmation',
    () {
      final (s, id) = seeded();
      final dense = s.get('quotation', id)!.data;
      expect(dense.keys, Quotation.fields);
      expect(dense.containsKey('notes'), isTrue);
      s.save('quotation', {...dense, 'notes': 'note'}, id: id);
      expect(() => s.save('quotation', dense, id: id), throwsFormatException);
      s.save('quotation', dense, id: id, allowClear: true);
      final stored =
          s.db.select('SELECT data FROM quotation WHERE id=?', [
                id,
              ]).single['data']
              as String;
      expect((jsonDecode(stored) as Map).containsKey('notes'), isFalse);
      expect(s.changes(id).last['new'], 'null');
      expect(s.get('quotation', id)!.data, dense);
    },
  );

  test('v4 migration keeps versions, timestamps, logs and business data', () {
    final (s, id) = seeded();
    s.delete('quotation', id);
    final expected = content(s);
    final path = v4File(s);
    final upgraded = Store.open(path, device: 'B');
    addTearDown(upgraded.close);
    expect(content(upgraded), expected);
    expect(upgraded.get('quotation', id)!.data, s.get('quotation', id)!.data);
    expect(
      upgraded.db
          .select("SELECT value FROM meta WHERE key='schema_version'")
          .single['value'],
      '$schemaVersion',
    );
    migrate(upgraded.db);
    expect(content(upgraded), expected, reason: 'reopening is idempotent');
  });

  test('v4 exchange migrates a copy and leaves original bytes unchanged', () {
    final (s, _) = seeded();
    final path = v4File(s);
    final bytes = File(path).readAsBytesSync();
    final target = device('B');
    addTearDown(target.close);
    expect(target.previewImport(path)['quotation']!.added, 1);
    target.importFrom(path);
    expect(content(target), content(s));
    expect(target.importFrom(path)['quotation']!.ignored, 1);
    expect(File(path).readAsBytesSync(), bytes);
  });

  test('unknown v4 fields roll the entire migration back', () {
    final (s, id) = seeded();
    final path = v4File(s);
    final db = sqlite3.open(path);
    addTearDown(db.close);
    db.execute(
      "UPDATE quotation SET data=json_set(data,'\$.unknown',1) WHERE id=?",
      [id],
    );
    final before = db.select('SELECT data FROM quotation').single['data'];
    expect(() => migrate(db), throwsFormatException);
    expect(
      db
          .select("SELECT value FROM meta WHERE key='schema_version'")
          .single['value'],
      '4',
    );
    expect(db.select('SELECT data FROM quotation').single['data'], before);
    expect(db.autocommit, isTrue);
  });

  test('concurrent null-to-value edits survive a sparse row-level winner', () {
    final (a, id) = seeded();
    final b = device('B', start: DateTime.utc(2026, 9, 2));
    addTearDown(b.close);
    b.importFrom(exported(a));
    final base = a.get('quotation', id)!.data;
    a.save('quotation', {...base, 'notes': 'A note'}, id: id);
    b.save('quotation', {...base, 'lead_time_days': 3}, id: id);
    a.importFrom(exported(b));
    b.importFrom(exported(a));
    expect(a.get('quotation', id)!.data['notes'], 'A note');
    expect(a.get('quotation', id)!.data['lead_time_days'], 3);
    expect(content(a), content(b));
    b.save(
      'quotation',
      {...b.get('quotation', id)!.data, 'notes': null},
      id: id,
      allowClear: true,
    );
    a.importFrom(exported(b));
    expect(a.get('quotation', id)!.data['notes'], isNull);
    expect(content(a), content(b));
  });

  test('v5 exchange rejects dense or unknown quotation fields atomically', () {
    final (s, _) = seeded();
    final target = device('B');
    addTearDown(target.close);
    for (final field in ['notes', 'unknown']) {
      final path = exported(s);
      final db = sqlite3.open(path);
      db.execute("UPDATE quotation SET data=json_set(data,'\$.$field',NULL)");
      db.close();
      expect(() => target.importFrom(path), throwsFormatException);
      expect(
        content(target),
        isEmpty,
        reason: 'all incoming entities roll back',
      );
    }
  });
}
