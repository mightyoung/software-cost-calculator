import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('siq-security'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String altered(void Function(Database) change) {
    final source = device('source');
    source.save('supplier', supplier('source'));
    final path = exported(source);
    source.close();
    final db = sqlite3.open(path);
    try {
      change(db);
    } finally {
      db.close();
    }
    return path;
  }

  for (final mode in [
    'view',
    'trigger',
    'computed',
    'virtual',
    'index',
    'check',
  ]) {
    test('rejects executable $mode schema before preview', () {
      final path = altered((db) {
        switch (mode) {
          case 'view':
            db.execute('DROP TABLE meta');
            db.execute(
              "CREATE VIEW meta AS SELECT 'format' AS key, '$fileFormat' AS value "
              "UNION ALL SELECT 'schema_version', '$schemaVersion'",
            );
          case 'trigger':
            db.execute(
              'CREATE TRIGGER hostile AFTER UPDATE ON meta '
              'BEGIN DELETE FROM supplier; END',
            );
          case 'computed':
            db.execute(
              'ALTER TABLE supplier ADD COLUMN surprise TEXT '
              'GENERATED ALWAYS AS (length(data)) VIRTUAL',
            );
          case 'virtual':
            db.execute('CREATE VIRTUAL TABLE hostile USING fts5(content)');
          case 'index':
            db.execute("CREATE INDEX hostile ON supplier(length(data))");
          case 'check':
            final sql =
                db
                        .select(
                          "SELECT sql FROM sqlite_schema WHERE name='supplier'",
                        )
                        .single['sql']
                    as String;
            db.execute('DROP TABLE supplier');
            db.execute(
              sql.replaceFirst(
                'data TEXT NOT NULL',
                'data TEXT NOT NULL CHECK(length(data)<100000)',
              ),
            );
        }
      });
      final target = device('target');
      addTearDown(target.close);
      expect(() => target.previewImport(path), throwsFormatException);
      expect(target.db.select('SELECT * FROM supplier'), isEmpty);
    });
  }

  test('rejects old schema trigger before migration runs it', () {
    final path = altered((db) {
      db.execute("UPDATE meta SET value='1' WHERE key='schema_version'");
      db.execute(
        'CREATE TRIGGER hostile AFTER UPDATE ON meta '
        'BEGIN DELETE FROM supplier; END',
      );
    });
    final target = device('target');
    addTearDown(target.close);
    expect(() => target.importFrom(path), throwsFormatException);
    expect(target.db.select('SELECT * FROM supplier'), isEmpty);
  });

  for (final change in <String, Object?>{
    'field': 'unknown_field',
    'device': '',
    'at': 'tomorrow',
    'new': '{broken',
    'old': '[broken',
  }.entries) {
    test('rejects invalid history ${change.key} atomically', () {
      final path = altered((db) {
        db.execute(
          "UPDATE change_log SET field='name', old='null', "
          "new='\"source\"'",
        );
        db.execute('UPDATE change_log SET ${change.key}=?', [change.value]);
      });
      final target = device('target');
      addTearDown(target.close);
      expect(() => target.importFrom(path), throwsFormatException);
      expect(target.db.select('SELECT * FROM supplier'), isEmpty);
      expect(target.db.select('SELECT * FROM change_log'), isEmpty);
    });
  }

  test('rejects non-null lifecycle marker values', () {
    final path = altered((db) {
      db.execute("UPDATE change_log SET new='\"hidden\"'");
    });
    final target = device('target');
    addTearDown(target.close);
    expect(() => target.importFrom(path), throwsFormatException);
  });

  test('history permits references that are no longer current records', () {
    final missing = newUuid();
    final path = altered((db) {
      db.execute(
        "UPDATE change_log SET entity_id=?, field='merged_into', old=?, new='null'",
        [missing, jsonEncode(newUuid())],
      );
    });
    final target = device('target');
    addTearDown(target.close);
    target.importFrom(path);
    expect(target.get('supplier', missing), isNull);
    expect(target.changes(missing), hasLength(1));
  });

  test('preserves resolution and lifecycle logs and deleted references', () {
    final source = device('source');
    final id = source.save('supplier', supplier('first'));
    source.save('supplier', supplier('second'), id: id);
    source.markResolved('supplier', id, 'name');
    source.delete('supplier', id);
    source.restore('supplier', id);
    source.delete('supplier', id);
    final target = device('target');
    addTearDown(source.close);
    addTearDown(target.close);
    target.importFrom(exported(source));
    expect(target.get('supplier', id)!.deleted, isTrue);
    expect(target.changes(id), source.changes(id));
    expect(
      target
          .changes(id)
          .any((r) => r['old'] == jsonEncode('second') && r['new'] == r['old']),
      isTrue,
    );
  });
}
