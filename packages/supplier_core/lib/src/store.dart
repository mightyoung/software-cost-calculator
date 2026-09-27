import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sqlite3/sqlite3.dart';

import 'entities.dart';
import 'quotation.dart';
import 'pricing.dart';
import 'search_index.dart';
import 'storage_codec.dart';
import 'values.dart';

/// 1: initial. 2: suppliers and products gain `merged_into`.
/// 3: quotation scope/award/provenance fields, inquiries, attachments.
/// 4: quotation price_basis, product attributes.
/// 5: quotation storage omits top-level null fields.
const schemaVersion = 6;
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
  'inquiry',
];

/// Reference columns checked after every write and every import.
const references = {
  'supplier': {'merged_into': 'supplier'},
  'product': {'merged_into': 'product'},
  'contact': {'supplier_id': 'supplier'},
  'quotation': {
    'supplier_id': 'supplier',
    'product_id': 'product',
    'contact_id': 'contact',
    'project_id': 'project',
    'inquiry_id': 'inquiry',
  },
  'inquiry': {'project_id': 'project'},
  'project_item': {
    'project_id': 'project',
    'product_id': 'product',
    'quotation_id': 'quotation',
  },
};

/// Reference lists (JSON arrays of ids), checked like [references].
const listReferences = {
  'inquiry': {'item_ids': 'project_item', 'supplier_ids': 'supplier'},
};

/// Largest attachment accepted, in bytes.
const maxAttachmentBytes = 20 * 1024 * 1024;

const _indexes = [
  "CREATE INDEX IF NOT EXISTS contact_supplier ON contact(json_extract(data,'\$.supplier_id'))",
  "CREATE INDEX IF NOT EXISTS quotation_product ON quotation(json_extract(data,'\$.product_id'))",
  "CREATE INDEX IF NOT EXISTS quotation_supplier ON quotation(json_extract(data,'\$.supplier_id'))",
  "CREATE INDEX IF NOT EXISTS quotation_project ON quotation(json_extract(data,'\$.project_id'))",
  "CREATE INDEX IF NOT EXISTS quotation_inquiry ON quotation(json_extract(data,'\$.inquiry_id'))",
  "CREATE INDEX IF NOT EXISTS item_project ON project_item(json_extract(data,'\$.project_id'))",
  'CREATE INDEX IF NOT EXISTS change_entity ON change_log(entity_id, at)',
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

/// Creates whatever tables and indexes are missing; safe to repeat, so
/// migrations reuse it to add tables introduced by later versions.
/// Attachments are immutable and content never changes under an id, so
/// they merge by id alone and carry no version.
void ensureTables(Database db) {
  db.execute(
    'CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
  );
  for (final type in entityTypes) {
    db.execute(
      'CREATE TABLE IF NOT EXISTS $type(id TEXT PRIMARY KEY, '
      'version INTEGER NOT NULL, updated_at TEXT NOT NULL, '
      'updated_by TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, '
      'data TEXT NOT NULL)',
    );
  }
  db.execute(
    'CREATE TABLE IF NOT EXISTS change_log(id TEXT PRIMARY KEY, '
    'entity TEXT NOT NULL, entity_id TEXT NOT NULL, field TEXT NOT NULL, '
    'old TEXT, new TEXT, device TEXT NOT NULL, at TEXT NOT NULL)',
  );
  db.execute(
    'CREATE TABLE IF NOT EXISTS attachment(id TEXT PRIMARY KEY, '
    'name TEXT NOT NULL, mime TEXT, size INTEGER NOT NULL, '
    'data BLOB NOT NULL, added_at TEXT NOT NULL, added_by TEXT NOT NULL)',
  );
  _indexes.forEach(db.execute);
}

void createSchema(Database db) {
  ensureTables(db);
  db.execute('INSERT INTO meta VALUES (?,?),(?,?)', [
    'format',
    fileFormat,
    'schema_version',
    '$schemaVersion',
  ]);
}

int _schemaOf(Database db) {
  final rows = db.select("SELECT value FROM meta WHERE key='schema_version'");
  return rows.isEmpty ? 0 : int.tryParse(rows.first['value'] as String) ?? 0;
}

/// Preserve a consistent, standalone copy before changing an older database.
/// A failed snapshot must stop the migration, leaving the original untouched.
void _backupBeforeMigration(Database db, String path, int from) {
  if (!File(path).existsSync()) return; // in-memory databases have no file
  final base = '$path.pre-v$from-migration';
  var backup = '$base.siq';
  for (var suffix = 1; File(backup).existsSync(); suffix++) {
    backup = '$base-$suffix.siq';
  }
  try {
    db.execute('VACUUM INTO ?', [backup]);
    final copy = sqlite3.open(backup, mode: OpenMode.readOnly);
    try {
      if (_schemaOf(copy) != from ||
          copy.select('PRAGMA quick_check').single.values.single != 'ok') {
        throw StateError('Migration backup failed integrity check');
      }
    } finally {
      copy.close();
    }
    final file = File(backup).openSync(mode: FileMode.append);
    try {
      file.flushSync();
    } finally {
      file.closeSync();
    }
  } catch (_) {
    final partial = File(backup);
    if (partial.existsSync()) partial.deleteSync();
    rethrow;
  }
}

/// Upgrades an older database in place, filling newly added optional fields
/// and canonicalizing storage. Versions and timestamps are kept:
/// migrating is not an edit, and two devices migrating the same row end up
/// with identical rows. Throws [StateError] for a newer or unknown schema.
void migrate(Database db) {
  final from = _schemaOf(db);
  if (from == schemaVersion) return;
  if (from < 1 || from > schemaVersion) {
    throw StateError('Unsupported database schema $from');
  }
  db.execute('BEGIN IMMEDIATE');
  try {
    ensureTables(db);
    for (final type in entityTypes) {
      final fields = payloadFields(type);
      for (final r in db.select('SELECT id, data FROM $type')) {
        final data = jsonDecode(r['data'] as String) as Map<String, Object?>;
        if (data.keys.any((key) => !fields.contains(key))) {
          invalid('$type.data', 'unknown field');
        }
        final full = {for (final f in fields) f: data[f]};
        db.execute('UPDATE $type SET data=? WHERE id=?', [
          encodeStoredPayload(type, full),
          r['id'],
        ]);
      }
    }
    db.execute("UPDATE meta SET value=? WHERE key='schema_version'", [
      '$schemaVersion',
    ]);
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}

/// Fixed-width UTC timestamp, so text order equals time order
/// (DateTime.toIso8601String drops trailing microsecond digits).
String stamp(DateTime t) {
  final u = t.toUtc();
  String pad(int n, [int w = 2]) => n.toString().padLeft(w, '0');
  return '${pad(u.year, 4)}-${pad(u.month)}-${pad(u.day)}T'
      '${pad(u.hour)}:${pad(u.minute)}:${pad(u.second)}.'
      '${pad(u.millisecond * 1000 + u.microsecond, 6)}Z';
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
    registerFunctions(db);
    db.execute('PRAGMA journal_mode=WAL');
    // A background import holds the write lock for a moment; wait for it.
    db.execute('PRAGMA busy_timeout=10000');
    if (db.select("SELECT 1 FROM sqlite_master WHERE name='meta'").isEmpty) {
      db.execute('BEGIN');
      createSchema(db);
      db.execute('COMMIT');
    }
    try {
      final from = _schemaOf(db);
      if (from >= 1 && from < schemaVersion) {
        _backupBeforeMigration(db, path, from);
      }
      migrate(db);
      ensureSearchIndex(db);
    } catch (_) {
      db.close();
      rethrow;
    }
    return Store(db, device: device, clock: clock);
  }

  final Database db;
  final String device;
  final DateTime Function() clock;

  void close() => db.close();

  DateTime? _floor;

  /// Hybrid logical clock: never earlier than any change this device has
  /// seen, so an edit made after receiving another device's edit sorts after
  /// it even when this device's clock runs behind.
  String _now() {
    _floor ??= DateTime.tryParse(
      db.select('SELECT max(at) AS at FROM change_log').first['at']
              as String? ??
          '',
    );
    var t = clock().toUtc();
    final floor = _floor;
    if (floor != null && !t.isAfter(floor)) {
      t = floor.add(const Duration(microseconds: 1));
    }
    _floor = t;
    return stamp(t);
  }

  /// Call after changes arrive from elsewhere (imports).
  void clockSeen() => _floor = null;

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
      Map.unmodifiable(decodeStoredPayload(type, r['data'] as String)),
    );
  }

  /// Creates when [id] is null, otherwise updates. Clearing a previously set
  /// quotation field requires [allowClear] (the UI asks the user first).
  String save(
    String type,
    Map<String, Object?> payload, {
    String? id,
    bool allowClear = false,
    String? snapshotSourceItemId,
  }) => transaction(() {
    final data = validatePayload(type, payload);
    final previous = id == null ? null : get(type, id);
    if (id != null && (previous == null || previous.deleted)) {
      invalid('id', 'record does not exist');
    }
    if (type == 'quotation') {
      _checkQuotation(data, previous, allowClear);
    }
    if (snapshotSourceItemId != null &&
        (type != 'project_item' ||
            previous != null ||
            !_sameItemSnapshot(data, snapshotSourceItemId))) {
      invalid('snapshotSourceItemId', 'not a matching budget snapshot');
    }
    if (type == 'project_item' && snapshotSourceItemId == null) {
      _checkItem(data, previous);
    }
    if (type == 'project' &&
        previous != null &&
        (previous.data['currency'] != data['currency'] ||
            previous.data['tax_mode'] != data['tax_mode'])) {
      final hasLine = db.select(
        "SELECT 1 FROM project_item WHERE deleted=0 "
        "AND json_extract(data,'\$.project_id')=? LIMIT 1",
        [id],
      ).isNotEmpty;
      if (hasLine || previous.data['contract_amount'] != null) {
        invalid(
          'currency',
          'clear budget and contract amount before changing project price basis',
        );
      }
    }
    if (type == 'product' &&
        previous != null &&
        previous.data['unit'] != data['unit'] &&
        (previous.data['unit_conversions'] as Map?)?.isNotEmpty == true &&
        jsonEncode(previous.data['unit_conversions']) ==
            jsonEncode(data['unit_conversions'])) {
      invalid(
        'unit_conversions',
        'clear or reconfigure conversions when changing the base unit',
      );
    }
    _checkReferences(type, data, previous);
    final key = id ?? newUuid();
    _write(type, key, (previous?.version ?? 0) + 1, false, data);
    _log(type, key, previous?.data, data);
    return key;
  });

  /// A copied budget line retains its historical cost even if its source
  /// quotation has since changed. The entire line must match an existing
  /// snapshot and both projects must use the same monetary basis.
  bool _sameItemSnapshot(Map<String, Object?> data, String sourceId) {
    final source = get('project_item', sourceId);
    if (source == null || source.deleted) return false;
    final from = get('project', source.data['project_id']! as String);
    final to = get('project', data['project_id']! as String);
    if (from == null || to == null || from.deleted || to.deleted) return false;
    if (from.data['currency'] != to.data['currency'] ||
        from.data['tax_mode'] != to.data['tax_mode'])
      return false;
    final sourceData = {...source.data}..remove('project_id');
    final copiedData = {...data}..remove('project_id');
    return jsonEncode(sourceData) == jsonEncode(copiedData);
  }

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
    [
      id,
      version,
      _now(),
      device,
      deleted ? 1 : 0,
      encodeStoredPayload(type, data),
    ],
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

  /// Records that [field] was reviewed and its current value kept, so a
  /// conflict on it is settled on every device that receives this log.
  void markResolved(String type, String id, String field) => transaction(() {
    final record = get(type, id);
    if (record == null || record.deleted)
      invalid('id', 'record does not exist');
    final value = jsonEncode(record.data[field]);
    _logRow(type, id, field, value, value);
  });

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
    // The snapshot is copied when a contact is chosen; later edits to the
    // contact (or its deletion) must not lock the quotation.
    final contactId = data['contact_id'] as String?;
    if (contactId == null) return;
    final contact = get('contact', contactId);
    if (contact == null) invalid('contact_id', 'unknown contact');
    if (previous?.data['contact_id'] == contactId) {
      if (contact.data['supplier_id'] != data['supplier_id']) {
        invalid('contact_id', 'contact or supplier does not match');
      }
      return;
    }
    if (contact.deleted) invalid('contact_id', 'unknown contact');
    quotation.validateContact(contactId, Contact.fromJson(contact.data));
  }

  /// A material line's price must come from a quotation for the same product
  /// in the project's currency, converted to its tax mode when needed.
  /// Existing cost snapshots survive subsequent quotation price changes.
  void _checkItem(Map<String, Object?> data, Record? previous) {
    final quotationId = data['quotation_id'] as String?;
    if (quotationId == null) return;
    final project = get('project', data['project_id']! as String);
    final quotation = get('quotation', quotationId);
    if (project == null || quotation == null) return; // reference check reports
    if (quotation.data['product_id'] != data['product_id']) {
      invalid('quotation_id', 'quotation is for another product');
    }
    if (previous?.data['quotation_id'] == quotationId &&
        previous?.data['project_id'] == data['project_id'] &&
        previous?.data['product_id'] == data['product_id'] &&
        previous?.data['unit'] == data['unit'] &&
        previous?.data['unit_cost'] == data['unit_cost'])
      return;
    final product = get('product', data['product_id']! as String);
    if (product == null) return;
    final normalized = priceInUnit(
      quotation.data,
      product: product.data,
      unit: data['unit']! as String,
      currency: project.data['currency']! as String,
      taxMode: project.data['tax_mode']! as String,
    );
    if (normalized == null) {
      invalid('quotation_id', 'currency, tax mode or unit cannot be converted');
    }
    if ((quotation.data['tax_mode'] != project.data['tax_mode'] ||
            quotation.data['unit_snapshot'] != data['unit']) &&
        micros(data['unit_cost']! as String) != micros(normalized) &&
        !(previous?.data['quotation_id'] == quotationId &&
            previous?.data['project_id'] == data['project_id'] &&
            previous?.data['product_id'] == data['product_id'] &&
            previous?.data['unit'] == data['unit'] &&
            previous?.data['unit_cost'] == data['unit_cost'])) {
      invalid('unit_cost', 'must use the project price basis');
    }
  }

  /// A newly set reference must point at a live record; one left unchanged
  /// may point at a record deleted since, so old records stay editable.
  void _checkReferences(
    String type,
    Map<String, Object?> data,
    Record? previous,
  ) {
    for (final MapEntry(key: field, value: target)
        in (references[type] ?? const <String, String>{}).entries) {
      final id = data[field];
      if (id == null) continue;
      final row = get(target, id as String);
      final kept = previous?.data[field] == id;
      if (row == null || (row.deleted && !kept)) {
        invalid(field, 'unknown $target');
      }
    }
    for (final MapEntry(key: field, value: target)
        in (listReferences[type] ?? const <String, String>{}).entries) {
      final before = {...?(previous?.data[field] as List?)};
      for (final id in data[field]! as List) {
        final row = get(target, id as String);
        if (row == null || (row.deleted && !before.contains(id))) {
          invalid(field, 'unknown $target');
        }
      }
    }
    if (type == 'quotation') {
      for (final id in (data['attachment_ids'] as List?) ?? const []) {
        if (db.select('SELECT 1 FROM attachment WHERE id=?', [id]).isEmpty) {
          invalid('attachment_ids', 'unknown attachment');
        }
      }
    }
  }

  void _type(String type) {
    if (!entityTypes.contains(type)) invalid('type', 'unknown entity type');
  }
}
