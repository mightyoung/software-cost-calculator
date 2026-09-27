import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'crypto_file.dart';
import 'store.dart';

/// Records that travel with a chosen one: a supplier brings its contacts,
/// a material its quotations, a project its budget lines, quotations and
/// inquiries.
const _children = {
  'supplier': [('contact', 'supplier_id')],
  'product': [('quotation', 'product_id')],
  'project': [
    ('project_item', 'project_id'),
    ('quotation', 'project_id'),
    ('inquiry', 'project_id'),
  ],
};

extension Share on Store {
  /// The chosen records, their children, and everything any of them refers
  /// to, so the receiver can import the selection on its own.
  Map<String, Set<String>> shareClosure(Map<String, Iterable<String>> chosen) {
    final out = {for (final t in entityTypes) t: <String>{}};
    final queue = <(String, String)>[];
    void add(String type, String id) {
      if (out[type]!.add(id)) queue.add((type, id));
    }

    chosen.forEach((type, ids) {
      for (final id in ids) {
        add(type, id);
        for (final (child, field)
            in _children[type] ?? const <(String, String)>[]) {
          for (final r in db.select(
            'SELECT id FROM $child WHERE '
            "json_extract(data,'\$.$field') = ?",
            [id],
          )) {
            add(child, r['id'] as String);
          }
        }
      }
    });
    while (queue.isNotEmpty) {
      final (type, id) = queue.removeLast();
      final data = get(type, id)?.data;
      if (data == null) continue;
      references[type]?.forEach((field, target) {
        if (data[field] case final String ref) add(target, ref);
      });
      listReferences[type]?.forEach((field, target) {
        for (final ref in (data[field] as List?) ?? const []) {
          add(target, ref as String);
        }
      });
    }
    return out;
  }

  /// Writes an exchange file holding only the [shareClosure] of [chosen]:
  /// its rows, their change history and the quotations' attachments. It
  /// imports like any exchange file. Encrypted when [passphrase] is given.
  Future<void> exportSelection(
    String path,
    Map<String, Iterable<String>> chosen, {
    String? passphrase,
  }) async {
    final ids = shareClosure(chosen);
    final plain = passphrase == null ? path : '$path.plain';
    for (final p in [plain, '$plain-journal']) {
      if (File(p).existsSync()) File(p).deleteSync();
    }
    final file = sqlite3.open(plain);
    try {
      createSchema(file);
    } finally {
      file.close();
    }
    final all = ids.values.expand((s) => s).toList();
    final attachments = {
      for (final q in ids['quotation']!)
        ...((get('quotation', q)?.data['attachment_ids'] as List?) ?? const [])
            .cast<String>(),
    };
    db.execute('ATTACH DATABASE ? AS out', [plain]);
    try {
      transaction(() {
        ids.forEach((type, set) {
          db.execute(
            'INSERT INTO out.$type SELECT * FROM main.$type '
            'WHERE id IN (SELECT value FROM json_each(?))',
            [jsonEncode(set.toList())],
          );
        });
        db.execute(
          'INSERT INTO out.change_log SELECT * FROM main.change_log '
          'WHERE entity_id IN (SELECT value FROM json_each(?))',
          [jsonEncode(all)],
        );
        db.execute(
          'INSERT INTO out.attachment SELECT * FROM main.attachment '
          'WHERE id IN (SELECT value FROM json_each(?))',
          [jsonEncode(attachments.toList())],
        );
      });
    } finally {
      db.execute('DETACH DATABASE out');
    }
    if (passphrase != null) {
      try {
        await encryptFile(plain, path, passphrase);
      } finally {
        File(plain).deleteSync();
      }
    }
  }
}
