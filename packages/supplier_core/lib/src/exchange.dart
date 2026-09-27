import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'merge.dart';
import 'quotation.dart';
import 'search_index.dart';
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

  /// Merges another device's file in one transaction. Any invalid row or
  /// dangling reference rolls the whole import back.
  Map<String, TableImport> importFrom(String path) => _attached(path, () {
    return transaction(() {
      final summary = _summary();
      final diverged = {for (final type in entityTypes) type: _diverged(type)};
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
          (id, deleted) => _mergeFields(type, id, deleted),
        );
      }
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
    if (version < schemaVersion) {
      temp = Directory.systemTemp.createTempSync('siq-migrate');
      attach = '${temp.path}/exchange.siq';
      File(path).copySync(attach);
      final copy = sqlite3.open(attach);
      registerFunctions(copy);
      try {
        migrate(copy);
      } on StateError {
        invalid('file', 'not a supported exchange file');
      } finally {
        copy.close();
      }
    }
    db.execute('ATTACH DATABASE ? AS src', [attach]);
    try {
      _checkFormat();
      return action();
    } finally {
      db.execute('DETACH DATABASE src');
      temp?.deleteSync(recursive: true);
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

  /// Field-level merge on top of the row-level winner: each field takes the
  /// value of its latest change in the combined change log, so edits to
  /// different fields on different devices are all kept. Deletion wins over
  /// edits. The result depends only on the combined log, so every device
  /// computes the same row. If the merged fields break a cross-field rule,
  /// the winning row is kept as it is.
  void _mergeFields(String type, String id, bool deleted) {
    final row = db.select('SELECT data FROM main.$type WHERE id=?', [id]);
    final current = row.first['data'] as String;
    final data = Map.of(jsonDecode(current) as Map<String, Object?>);
    for (final r in db.select(
      "SELECT field, new FROM main.change_log WHERE entity=? AND entity_id=? "
      "AND field NOT LIKE '(%' ORDER BY at, device, id",
      [type, id],
    )) {
      final field = r['field'] as String;
      if (data.containsKey(field)) data[field] = jsonDecode(r['new'] as String);
    }
    var merged = current;
    try {
      merged = jsonEncode(validatePayload(type, data));
    } on FormatException {
      // keep the row-level winner
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
      final data = jsonDecode(r['data'] as String);
      if (data is! Map<String, Object?>)
        invalid('$type.data', 'expected object');
      if (jsonEncode(validatePayload(type, data)) != r['data']) {
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
