import 'dart:convert';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import 'entities.dart';
import 'quotation.dart';
import 'values.dart';

const schemaVersion = 1;
const fileFormat = 'supplier-inquiry';

/// Merge order matters only for the reference check at the end of an import;
/// parents come first so the same list drives creation-order display too.
const entityTypes = [
  'supplier',
  'contact',
  'product',
  'project',
  'quotation',
  'project_item',
];

/// Reference columns checked after every write and every import.
const references = {
  'contact': {'supplier_id': 'supplier'},
  'quotation': {
    'supplier_id': 'supplier',
    'product_id': 'product',
    'contact_id': 'contact',
    'project_id': 'project',
  },
  'project_item': {
    'project_id': 'project',
    'product_id': 'product',
    'quotation_id': 'quotation',
  },
};

const _indexes = [
  "CREATE INDEX contact_supplier ON contact(json_extract(data,'\$.supplier_id'))",
  "CREATE INDEX quotation_product ON quotation(json_extract(data,'\$.product_id'))",
  "CREATE INDEX quotation_supplier ON quotation(json_extract(data,'\$.supplier_id'))",
  "CREATE INDEX quotation_project ON quotation(json_extract(data,'\$.project_id'))",
  "CREATE INDEX item_project ON project_item(json_extract(data,'\$.project_id'))",
  'CREATE INDEX change_entity ON change_log(entity_id, at)',
];

String newUuid() {
  final random = Random.secure();
  final b = List<int>.generate(16, (_) => random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

void createSchema(Database db) {
  db.execute('CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  for (final type in entityTypes) {
    db.execute(
      'CREATE TABLE $type(id TEXT PRIMARY KEY, version INTEGER NOT NULL, '
      'updated_at TEXT NOT NULL, updated_by TEXT NOT NULL, '
      'deleted INTEGER NOT NULL DEFAULT 0, data TEXT NOT NULL)',
    );
  }
  db.execute(
    'CREATE TABLE change_log(id TEXT PRIMARY KEY, entity TEXT NOT NULL, '
    'entity_id TEXT NOT NULL, field TEXT NOT NULL, old TEXT, new TEXT, '
    'device TEXT NOT NULL, at TEXT NOT NULL)',
  );
  _indexes.forEach(db.execute);
  db.execute('INSERT INTO meta VALUES (?,?),(?,?)', [
    'format',
    fileFormat,
    'schema_version',
    '$schemaVersion',
  ]);
}

class Record {
  Record(this.type, this.id, this.version, this.deleted, this.data);
  final String type, id;
  final int version;
  final bool deleted;
  final Map<String, Object?> data;
}

/// One device's database. Every business change goes through [save] or
/// [delete]; both bump the record version and append to the change log in
/// the same transaction, which is what exchange merging relies on.
class Store {
  Store(this.db, {required this.device, DateTime Function()? clock})
    : clock = clock ?? DateTime.now;

  factory Store.open(
    String path, {
    required String device,
    DateTime Function()? clock,
  }) {
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode=WAL');
    if (db.select("SELECT 1 FROM sqlite_master WHERE name='meta'").isEmpty) {
      db.execute('BEGIN');
      createSchema(db);
      db.execute('COMMIT');
    }
    final version = db.select(
      "SELECT value FROM meta WHERE key='schema_version'",
    );
    if (version.isEmpty || version.first['value'] != '$schemaVersion') {
      db.close();
      throw StateError('Unsupported database schema');
    }
    return Store(db, device: device, clock: clock);
  }

  final Database db;
  final String device;
  final DateTime Function() clock;

  void close() => db.close();

  String _now() => clock().toUtc().toIso8601String();

  /// Re-entrant: nested calls join the outer transaction.
  T transaction<T>(T Function() action) {
    if (!db.autocommit) return action();
    db.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      db.execute('COMMIT');
      return result;
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  Record? get(String type, String id) {
    _type(type);
    final rows = db.select('SELECT * FROM $type WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return Record(
      type,
      id,
      r['version'] as int,
      r['deleted'] == 1,
      Map.unmodifiable(jsonDecode(r['data'] as String) as Map<String, Object?>),
    );
  }

  /// Creates when [id] is null, otherwise updates. Clearing a previously set
  /// quotation field requires [allowClear] (the UI asks the user first).
  String save(
    String type,
    Map<String, Object?> payload, {
    String? id,
    bool allowClear = false,
  }) => transaction(() {
    final data = validatePayload(type, payload);
    final previous = id == null ? null : get(type, id);
    if (id != null && (previous == null || previous.deleted)) {
      invalid('id', 'record does not exist');
    }
    if (type == 'quotation') {
      _checkQuotation(data, previous, allowClear);
    }
    if (type == 'project_item') _checkItem(data);
    _checkReferences(type, data);
    final key = id ?? newUuid();
    _write(type, key, (previous?.version ?? 0) + 1, false, data);
    _log(type, key, previous?.data, data);
    return key;
  });

  void delete(String type, String id) => transaction(() {
    final previous = get(type, id);
    if (previous == null || previous.deleted) {
      invalid('id', 'record does not exist');
    }
    _write(type, id, previous.version + 1, true, previous.data);
    _logRow(type, id, '(deleted)', null, null);
  });

  void _write(
    String type,
    String id,
    int version,
    bool deleted,
    Map<String, Object?> data,
  ) => db.execute(
    'INSERT INTO $type VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET '
    'version=excluded.version, updated_at=excluded.updated_at, '
    'updated_by=excluded.updated_by, deleted=excluded.deleted, '
    'data=excluded.data',
    [id, version, _now(), device, deleted ? 1 : 0, jsonEncode(data)],
  );

  void _log(
    String type,
    String id,
    Map<String, Object?>? before,
    Map<String, Object?> after,
  ) {
    if (before == null) return _logRow(type, id, '(created)', null, null);
    for (final field in after.keys) {
      final old = jsonEncode(before[field]);
      final now = jsonEncode(after[field]);
      if (old != now) _logRow(type, id, field, old, now);
    }
  }

  void _logRow(
    String type,
    String id,
    String field,
    String? old,
    String? now,
  ) => db.execute('INSERT INTO change_log VALUES (?,?,?,?,?,?,?,?)', [
    newUuid(),
    type,
    id,
    field,
    old,
    now,
    device,
    _now(),
  ]);

  List<Map<String, Object?>> changes(String id) => [
    for (final r in db.select(
      'SELECT field, old, new, device, at FROM change_log '
      'WHERE entity_id=? ORDER BY at, id',
      [id],
    ))
      Map.of(r),
  ];

  void _checkQuotation(
    Map<String, Object?> data,
    Record? previous,
    bool allowClear,
  ) {
    final quotation = Quotation.fromJson(data);
    if (previous != null) {
      quotation.validateEditFrom(
        Quotation.fromJson(previous.data),
        allowExplicitClear: allowClear,
      );
    } else if (data['capture_mode'] != 'standard') {
      invalid('capture_mode', 'historical records come only from imports');
    }
    final contactId = data['contact_id'] as String?;
    if (contactId != null) {
      final contact = get('contact', contactId);
      if (contact == null || contact.deleted) {
        invalid('contact_id', 'unknown contact');
      }
      quotation.validateContact(contactId, Contact.fromJson(contact.data));
    }
  }

  /// A material line's price must come from a quotation for the same product
  /// in the project's currency and tax mode; there is no FX conversion.
  void _checkItem(Map<String, Object?> data) {
    final quotationId = data['quotation_id'] as String?;
    if (quotationId == null) return;
    final project = get('project', data['project_id']! as String);
    final quotation = get('quotation', quotationId);
    if (project == null || quotation == null) return; // reference check reports
    if (quotation.data['product_id'] != data['product_id']) {
      invalid('quotation_id', 'quotation is for another product');
    }
    if (quotation.data['currency'] != project.data['currency'] ||
        quotation.data['tax_mode'] != project.data['tax_mode']) {
      invalid('quotation_id', 'currency or tax mode differs from project');
    }
  }

  void _checkReferences(String type, Map<String, Object?> data) {
    for (final MapEntry(key: field, value: target)
        in (references[type] ?? const <String, String>{}).entries) {
      final id = data[field];
      if (id == null) continue;
      final row = get(target, id as String);
      if (row == null || row.deleted) invalid(field, 'unknown $target');
    }
  }

  void _type(String type) {
    if (!entityTypes.contains(type)) invalid('type', 'unknown entity type');
  }
}
