import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'merge.dart';
import 'search_index.dart';
import 'storage_codec.dart';
import 'store.dart';
import 'values.dart';

/// Per-table import outcome. [merged] counts records where this device's
/// version wins but the file's differs: their fields are merged in.
/// [conflicts] lists ids both sides edited from the same version.
class TableImport {
  TableImport(
    this.added,
    this.updated,
    this.ignored,
    this.conflicts, {
    this.merged = 0,
  });
  final int added, updated, ignored, merged;
  final List<String> conflicts;
}

// A row from the other side wins when its (version, updated_at, updated_by)
// tuple is greater. That is a total order, so merging is order-independent
// and idempotent.
const _wins =
    '(s.version, s.updated_at, s.updated_by) > (m.version, m.updated_at, m.updated_by)';

extension Exchange on Store {
  /// Writes a consistent snapshot. The same file is the weekly exchange file
  /// and the backup: importing it into an empty database restores it.
  void exportTo(String path) {
    final part = '$path.part';
    final partial = File(part);
    if (partial.existsSync()) partial.deleteSync();
    db.execute('VACUUM INTO ?', [part]);
    final copy = sqlite3.open(part);
    try {
      dropSearchIndex(copy);
      copy.execute('VACUUM');
    } finally {
      copy.close();
    }
    partial.renameSync(path);
  }

  /// Writes today's snapshot into [dir] unless one exists, and keeps only
  /// the newest [keep]. Returns the new file, or null when today's exists.
  String? dailyBackup(String dir, {int keep = 7, DateTime? now}) {
    final day = localDay(now ?? clock());
    final folder = Directory(dir)..createSync(recursive: true);
    final path = '${folder.path}/自动备份-$day.siq';
    if (File(path).existsSync()) return null;
    exportTo(path);
    final backups =
        folder
            .listSync()
            .whereType<File>()
            .where((f) => f.path.contains('自动备份-') && f.path.endsWith('.siq'))
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    for (final old in backups.skip(keep)) {
      old.deleteSync();
    }
    return path;
  }

  Map<String, TableImport> previewImport(String path) =>
      _attached(path, () => _summary());

  /// Counts the live records in a snapshot without changing either library.
  Map<String, int> snapshotCounts(String path) => _attached(
    path,
    () => {
      for (final type in entityTypes)
        type: _count('SELECT count(*) FROM src.$type WHERE deleted=0'),
    },
  );

  /// Replaces this library, preserving the connection and local device identity.
  /// The caller supplies a fresh backup filename; existing backups are never
  /// overwritten. A concurrent write since the backup aborts the replacement.
  void replaceFrom(String path, {required String safetyBackupPath}) {
    if (!db.autocommit) {
      invalid('restore', 'cannot restore inside another transaction');
    }
    final livePath =
        db
                .select('PRAGMA database_list')
                .firstWhere((row) => row['name'] == 'main')['file']
            as String;
    if (livePath.isNotEmpty &&
        File(path).existsSync() &&
        FileSystemEntity.identicalSync(livePath, path)) {
      invalid('file', 'choose a snapshot, not the active library');
    }
    final backup = File(safetyBackupPath);
    if (backup.existsSync() || File('$safetyBackupPath.part').existsSync()) {
      invalid('backup', 'choose a new safety backup path');
    }
    _attached(path, () {
      backup.parent.createSync(recursive: true);
      exportTo(safetyBackupPath);
      db.execute('ATTACH DATABASE ? AS restore_backup', [safetyBackupPath]);
      try {
        final check = db.select('PRAGMA restore_backup.quick_check');
        if (check.length != 1 || check.first.values.first != 'ok') {
          invalid('backup', 'safety backup verification failed');
        }
        transaction(() {
          // Verify the complete backup against the locked current library,
          // including blobs and history, before deleting any live rows.
          for (final table in [...entityTypes, 'change_log', 'attachment']) {
            for (final pair in [
              ['main', 'restore_backup'],
              ['restore_backup', 'main'],
            ]) {
              if (db
                  .select(
                    'SELECT * FROM ${pair[0]}.$table EXCEPT '
                    'SELECT * FROM ${pair[1]}.$table LIMIT 1',
                  )
                  .isNotEmpty) {
                invalid('backup', 'library changed since safety backup');
              }
            }
          }
          for (final table in [...entityTypes, 'change_log', 'attachment']) {
            db.execute('DELETE FROM main.$table');
          }
          _importAttachments();
          for (final type in entityTypes) {
            // Local tables are empty, so every incoming row is validated.
            _validateIncoming(type);
            db.execute(
              'INSERT INTO main.$type '
              'SELECT id, version, updated_at, updated_by, deleted, data '
              'FROM src.$type',
            );
          }
          _validateIncomingLog();
          db.execute(
            'INSERT INTO main.change_log '
            'SELECT id, entity, entity_id, field, old, new, device, at '
            'FROM src.change_log',
          );
          checkAllReferences();
          // Existing search triggers maintain indexes inside this transaction.
        });
        clockSeen();
      } finally {
        db.execute('DETACH DATABASE restore_backup');
      }
    });
  }

  /// Merges another device's file in one transaction. Any invalid row or
  /// dangling reference rolls the whole import back.
  Map<String, TableImport> importFrom(String path) => _attached(path, () {
    return transaction(() {
      final summary = _summary();
      final diverged = {for (final type in entityTypes) type: _diverged(type)};
      final basisBefore = {
        for (final type in ['product', 'project', 'quotation', 'project_item'])
          type: _localBasis(type),
      };
      final projectItemsBefore = {
        for (final id in basisBefore['project']!.keys)
          id: _itemBasesForProject('main', id),
      };
      _importAttachments();
      for (final type in entityTypes) {
        _validateIncoming(type);
        db.execute(
          'INSERT INTO main.$type SELECT s.id, s.version, s.updated_at, '
          's.updated_by, s.deleted, s.data FROM src.$type s '
          'LEFT JOIN main.$type m ON m.id = s.id '
          'WHERE m.id IS NULL OR $_wins '
          'ON CONFLICT(id) DO UPDATE SET version=excluded.version, '
          'updated_at=excluded.updated_at, updated_by=excluded.updated_by, '
          'deleted=excluded.deleted, data=excluded.data',
        );
      }
      _validateIncomingLog();
      db.execute(
        'INSERT OR IGNORE INTO main.change_log '
        'SELECT id, entity, entity_id, field, old, new, device, at '
        'FROM src.change_log',
      );
      for (final type in entityTypes) {
        diverged[type]!.forEach(
          (id, deleted) =>
              _mergeFields(type, id, deleted, original: basisBefore[type]?[id]),
        );
      }
      _checkProjectBasisImports(basisBefore['project']!, projectItemsBefore);
      clockSeen();
      redirectMerged();
      checkAllReferences();
      return summary;
    });
  });

  /// Throws when any stored reference points at a missing record.
  void checkAllReferences() {
    for (final MapEntry(key: type, value: fields) in listReferences.entries) {
      for (final MapEntry(key: field, value: target) in fields.entries) {
        final bad = db.select(
          "SELECT t.id FROM main.$type t, json_each(t.data,'\$.$field') j "
          "WHERE j.type = 'text' AND j.value NOT IN (SELECT id FROM main.$target) LIMIT 1",
        );
        if (bad.isNotEmpty) invalid('$type.$field', 'missing $target record');
      }
    }
    final orphan = db.select(
      "SELECT q.id FROM main.quotation q, json_each(q.data,'\$.attachment_ids') j "
      "WHERE j.type = 'text' AND j.value NOT IN (SELECT id FROM main.attachment) LIMIT 1",
    );
    if (orphan.isNotEmpty) {
      invalid('quotation.attachment_ids', 'missing attachment');
    }
    for (final MapEntry(key: type, value: fields) in references.entries) {
      for (final MapEntry(key: field, value: target) in fields.entries) {
        final bad = db.select(
          "SELECT id FROM main.$type WHERE json_extract(data,'\$.$field') "
          "IS NOT NULL AND json_extract(data,'\$.$field') NOT IN "
          '(SELECT id FROM main.$target) LIMIT 1',
        );
        if (bad.isNotEmpty) invalid('$type.$field', 'missing $target record');
      }
    }
  }

  /// Attaches [path] as `src`. A file from an older version is migrated in
  /// a temporary copy first, so the user's file is never modified.
  T _attached<T>(String path, T Function() action) {
    if (!File(path).existsSync()) invalid('file', 'not found');
    final version = _fileVersion(path);
    if (version > schemaVersion) {
      invalid('file', 'made by a newer version; upgrade this device first');
    }
    Directory? temp;
    var attach = path;
    var attached = false;
    try {
      if (version < schemaVersion) {
        temp = Directory.systemTemp.createTempSync('siq-migrate');
        attach = '${temp.path}/exchange.siq';
        File(path).copySync(attach);
        final copy = sqlite3.open(attach);
        try {
          registerFunctions(copy);
          migrate(copy);
        } on StateError {
          invalid('file', 'not a supported exchange file');
        } finally {
          copy.close();
        }
      }
      db.execute('ATTACH DATABASE ? AS src', [attach]);
      attached = true;
      _checkFormat();
      return action();
    } finally {
      try {
        if (attached) db.execute('DETACH DATABASE src');
      } finally {
        temp?.deleteSync(recursive: true);
      }
    }
  }

  int _fileVersion(String path) {
    try {
      final file = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        final rows = file.select(
          "SELECT value FROM meta WHERE key='schema_version'",
        );
        return rows.isEmpty
            ? 0
            : int.tryParse(rows.first['value'] as String) ?? 0;
      } finally {
        file.close();
      }
    } on SqliteException {
      invalid('file', 'not a supported exchange file');
    }
  }

  void _checkFormat() {
    try {
      final meta = {
        for (final r in db.select('SELECT key, value FROM src.meta'))
          r['key']: r['value'],
      };
      if (meta['format'] != fileFormat ||
          meta['schema_version'] != '$schemaVersion') {
        invalid('file', 'not a supported exchange file');
      }
      final check = db.select('PRAGMA src.quick_check');
      if (check.length != 1 || check.first.values.first != 'ok') {
        invalid('file', 'damaged');
      }
    } on FormatException {
      rethrow;
    } on Exception {
      invalid('file', 'not a supported exchange file');
    }
  }

  Map<String, TableImport> _summary() => {
    for (final type in entityTypes)
      type: TableImport(
        _count(
          'SELECT count(*) FROM src.$type s WHERE s.id NOT IN '
          '(SELECT id FROM main.$type)',
        ),
        _count(
          'SELECT count(*) FROM src.$type s JOIN main.$type m '
          'ON m.id = s.id WHERE $_wins',
        ),
        _count(
          'SELECT count(*) FROM src.$type s JOIN main.$type m '
          'ON m.id = s.id WHERE NOT $_wins '
          'AND s.data = m.data AND s.deleted = m.deleted',
        ),
        [
          for (final r in db.select(
            'SELECT s.id FROM src.$type s JOIN main.$type m ON m.id = s.id '
            'WHERE s.version = m.version '
            'AND (s.data <> m.data OR s.deleted <> m.deleted)',
          ))
            r['id'] as String,
        ],
        merged: _count(
          'SELECT count(*) FROM src.$type s JOIN main.$type m '
          'ON m.id = s.id WHERE NOT $_wins '
          'AND (s.data <> m.data OR s.deleted <> m.deleted)',
        ),
      ),
  };

  /// Attachments never change under an id, so new ones are simply added.
  void _importAttachments() {
    for (final r in db.select(
      'SELECT id, name, mime, size, length(data) AS len, added_at, added_by '
      'FROM src.attachment WHERE id NOT IN (SELECT id FROM main.attachment)',
    )) {
      requireUuid(r['id'], 'attachment.id');
      normalizeText(r['name'], 'attachment.name', 200, required: true);
      normalizeText(r['mime'], 'attachment.mime', 100);
      normalizeText(r['added_by'], 'attachment.added_by', 100, required: true);
      if (r['size'] != r['len'] || (r['len'] as int) > maxAttachmentBytes) {
        invalid('attachment.size', 'does not match its content');
      }
      if (DateTime.tryParse(r['added_at'] as String? ?? '') == null) {
        invalid('attachment.added_at', 'expected timestamp');
      }
    }
    db.execute(
      'INSERT OR IGNORE INTO main.attachment SELECT id, name, mime, size, '
      'data, added_at, added_by FROM src.attachment',
    );
  }

  /// Records both sides hold with different content, and whether either
  /// side deleted it. Read before the row-level merge overwrites one side.
  Map<String, bool> _diverged(String type) => {
    for (final r in db.select(
      'SELECT s.id, max(s.deleted, m.deleted) AS deleted FROM src.$type s '
      'JOIN main.$type m ON m.id = s.id '
      'WHERE s.data <> m.data OR s.deleted <> m.deleted',
    ))
      r['id'] as String: r['deleted'] == 1,
  };

  // Prices and their quoted unit/tax/reference, budget amounts and their
  // unit/reference, or a product's base unit and factors form one basis.
  // Field replay must not splice a basis that neither device held.
  /// Fields that must come from one device together. A budget line's
  /// quantity joins them only when the two sides use different units (1 米
  /// and 0.001 千米 are the same amount).
  List<String> _basisFields(
    String type, [
    Map<String, Object?>? local,
    Map<String, Object?>? incoming,
  ]) {
    final fields = switch (type) {
      'product' => const ['unit', 'unit_conversions'],
      'project' => const ['currency', 'tax_mode', 'contract_amount'],
      'quotation' => const [
        'product_id',
        'currency',
        'tax_mode',
        'tax_rate',
        'unit_snapshot',
        'price',
        'deal_price',
        'min_qty',
        'extra_cost',
        'price_tiers',
      ],
      // Quantity is not part of the price: a refreshed price and a changed
      // quantity from two devices combine into a valid line.
      _ => [
        'project_id',
        'product_id',
        'quotation_id',
        'unit',
        'unit_cost',
        'unit_price',
        if (type == 'project_item' &&
            local != null &&
            incoming != null &&
            local['unit'] != incoming['unit'])
          'qty',
      ],
    };
    return fields;
  }

  String _basis(
    String type,
    Map<String, Object?> data, [
    List<String>? fields,
  ]) => jsonEncode([for (final f in fields ?? _basisFields(type)) data[f]]);

  String _basisKey(String type, Map<String, Object?> data) {
    final fields = switch (type) {
      'product' => const ['unit'],
      'project' => const ['currency', 'tax_mode'],
      'quotation' => const [
        'product_id',
        'currency',
        'tax_mode',
        'tax_rate',
        'unit_snapshot',
      ],
      _ => const ['project_id', 'product_id', 'quotation_id', 'unit'],
    };
    return jsonEncode([for (final field in fields) data[field]]);
  }

  /// Local rows about to meet an incoming row with another price basis.
  Map<String, Map<String, Object?>> _localBasis(String type) {
    final result = <String, Map<String, Object?>>{};
    for (final row in db.select(
      'SELECT m.id, m.data AS local_data, s.data AS incoming_data '
      'FROM main.$type m JOIN src.$type s ON s.id=m.id '
      'WHERE m.data <> s.data',
    )) {
      final local = decodeStoredPayload(type, row['local_data'] as String);
      final incoming = decodeStoredPayload(
        type,
        row['incoming_data'] as String,
      );
      if (_basisKey(type, local) != _basisKey(type, incoming)) {
        result[row['id'] as String] = local;
      }
    }
    return result;
  }

  Map<String, String> _itemBasesForProject(String schema, String projectId) => {
    for (final row in db.select(
      'SELECT id, data FROM $schema.project_item WHERE deleted=0 '
      "AND json_extract(data,'\$.project_id')=?",
      [projectId],
    ))
      row['id'] as String: _basis(
        'project_item',
        decodeStoredPayload('project_item', row['data'] as String),
      ),
  };

  void _checkProjectBasisImports(
    Map<String, Map<String, Object?>> localBasis,
    Map<String, Map<String, String>> localItems,
  ) {
    for (final id in localBasis.keys) {
      final merged = get('project', id);
      if (merged == null || merged.deleted) continue;
      final choseLocal =
          _basis('project', merged.data) == _basis('project', localBasis[id]!);
      final chosenItems = choseLocal
          ? localItems[id]!
          : _itemBasesForProject('src', id);
      final finalItems = _itemBasesForProject('main', id);
      for (final entry in finalItems.entries) {
        if (chosenItems[entry.key] != entry.value) {
          // Line amounts cannot be told apart once the project's currency or
          // tax mode changed on another device: stop and let people decide.
          throw FormatException(
            '项目「${merged.data['name']}」的币种或含税口径在另一台设备上改过，'
            '同时两边都改了它的预算行。请两台设备先统一这个项目的币种和含税口径，再交换',
          );
        }
      }
    }
  }

  /// Field-level merge on top of the row-level winner: each field takes the
  /// value of its latest change in the combined change log, so edits to
  /// different fields on different devices are all kept. Deletion wins over
  /// edits; only an explicit restore, if it is the latest, brings a record
  /// back. The result depends only on the combined log, so every device
  /// computes the same row. Exchange never stops on a merge: a price basis
  /// that neither device held (say one changed the unit, the other the
  /// price) is taken whole from the row-level winner, and merged fields that
  /// break a cross-field rule leave the whole winning row. The overridden
  /// edits stay in the change log.
  void _mergeFields(
    String type,
    String id,
    bool wasDeleted, {
    Map<String, Object?>? original,
  }) {
    var deleted = wasDeleted;
    // A record comes back only through an explicit restore: the latest
    // delete or restore in the combined log decides, edits never do.
    final marker = db.select(
      "SELECT field FROM main.change_log WHERE entity=? AND entity_id=? "
      "AND field IN ('(deleted)', '(restored)') "
      'ORDER BY at DESC, device DESC, id DESC LIMIT 1',
      [type, id],
    );
    if (marker.isNotEmpty) deleted = marker.single['field'] == '(deleted)';
    final row = db.select('SELECT data FROM main.$type WHERE id=?', [id]);
    final current = row.first['data'] as String;
    final data = decodeStoredPayload(type, current);
    for (final r in db.select(
      "SELECT field, new FROM main.change_log WHERE entity=? AND entity_id=? "
      "AND field NOT LIKE '(%' ORDER BY at, device, id",
      [type, id],
    )) {
      final field = r['field'] as String;
      if (data.containsKey(field)) data[field] = jsonDecode(r['new'] as String);
    }
    if (!deleted && original != null) {
      final incoming = decodeStoredPayload(
        type,
        db.select('SELECT data FROM src.$type WHERE id=?', [id]).single['data']
            as String,
      );
      final fields = _basisFields(type, original, incoming);
      final mergedBasis = _basis(type, data, fields);
      if (mergedBasis != _basis(type, original, fields) &&
          mergedBasis != _basis(type, incoming, fields)) {
        final winner = decodeStoredPayload(type, current);
        for (final field in fields) {
          data[field] = winner[field];
        }
      }
    }
    String merged;
    try {
      merged = encodeStoredPayload(type, data);
    } on FormatException {
      merged = current; // keep the row-level winner
    }
    db.execute('UPDATE main.$type SET data=?, deleted=? WHERE id=?', [
      merged,
      deleted ? 1 : 0,
      id,
    ]);
  }

  int _count(String sql) => db.select(sql).first.values.first as int;

  /// Only rows that will overwrite local data need checking; losing rows are
  /// never read into the local database.
  void _validateIncoming(String type) {
    for (final r in db.select(
      'SELECT s.* FROM src.$type s LEFT JOIN main.$type m ON m.id = s.id '
      'WHERE m.id IS NULL OR $_wins',
    )) {
      requireUuid(r['id'], '$type.id');
      requireSafeInteger(r['version'], '$type.version', min: 1);
      if (r['deleted'] != 0 && r['deleted'] != 1) {
        invalid('$type.deleted', 'expected 0 or 1');
      }
      normalizeText(r['updated_by'], '$type.updated_by', 100, required: true);
      final at = r['updated_at'];
      if (at is! String || DateTime.tryParse(at) == null) {
        invalid('$type.updated_at', 'expected timestamp');
      }
      final data = decodeStoredPayload(type, r['data'] as String);
      if (encodeStoredPayload(type, data) != r['data']) {
        invalid('$type.data', 'not in canonical form');
      }
    }
  }

  void _validateIncomingLog() {
    for (final r in db.select(
      'SELECT id, entity, entity_id FROM src.change_log '
      'WHERE id NOT IN (SELECT id FROM main.change_log)',
    )) {
      requireUuid(r['id'], 'change_log.id');
      requireUuid(r['entity_id'], 'change_log.entity_id');
      if (!entityTypes.contains(r['entity'])) {
        invalid('change_log.entity', 'unknown entity type');
      }
    }
  }
}
