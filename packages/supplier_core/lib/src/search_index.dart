import 'package:lpinyin/lpinyin.dart';
import 'package:sqlite3/sqlite3.dart';

/// Searchable text per entity type, one index column each. Every index also
/// gets an `initials` column: pinyin initials of the name and aliases.
const searchColumns = {
  'product': [
    'model',
    'name',
    'brand',
    'specification',
    'category',
    'attributes',
  ],
  'supplier': ['name', 'aliases'],
  'project': ['name', 'code'],
};

/// Pinyin initials in lower case, other characters kept: "离心泵" -> "lxb".
String pinyinInitials(String s) =>
    PinyinHelper.getShortPinyin(s).toLowerCase().replaceAll(RegExp(r'\s'), '');

/// Index table of [type]. The suffix is bumped when the columns change so
/// the new index is built beside the old one.
String searchTable(String type) => '${type}_search1';

/// SQL functions the index triggers call; needed on every connection that
/// writes entity rows.
void registerFunctions(Database db) => db.createFunction(
  functionName: 'pinyin_initials',
  argumentCount: const AllowedArgumentCount(1),
  deterministic: true,
  // Called from the index triggers; pure text in, text out.
  directOnly: false,
  function: (args) => pinyinInitials(args[0] as String? ?? ''),
);

/// Creates the trigram full-text indexes and the triggers that keep them in
/// step with every write (edits, imports, merges, migrations), then fills
/// them once. Only live, unmerged rows are indexed. The index is local to
/// this database: imports read the entity tables only.
void ensureSearchIndex(Database db) {
  for (final MapEntry(key: type, value: columns) in searchColumns.entries) {
    final t = searchTable(type);
    final fresh = db.select('SELECT 1 FROM sqlite_master WHERE name = ?', [
      t,
    ]).isEmpty;
    final names = [...columns, 'initials'].join(', ');
    String values(String row) => [
      for (final c in columns) "json_extract($row.data,'\$.$c')",
      "pinyin_initials(coalesce(json_extract($row.data,'\$.name'),'') || '|' "
          "|| coalesce(json_extract($row.data,'\$.aliases'),''))",
    ].join(', ');
    String live(String row) =>
        "$row.deleted = 0 AND json_extract($row.data,'\$.merged_into') IS NULL";
    final insert =
        'INSERT INTO $t(rowid, $names) SELECT new.rowid, ${values('new')} '
        'WHERE ${live('new')};';
    db
      ..execute(
        "CREATE VIRTUAL TABLE IF NOT EXISTS $t USING fts5($names, "
        "tokenize='trigram')",
      )
      ..execute(
        'CREATE TRIGGER IF NOT EXISTS ${t}_ai AFTER INSERT ON $type '
        'BEGIN $insert END',
      )
      ..execute(
        'CREATE TRIGGER IF NOT EXISTS ${t}_au AFTER UPDATE ON $type '
        'BEGIN DELETE FROM $t WHERE rowid = old.rowid; $insert END',
      )
      ..execute(
        'CREATE TRIGGER IF NOT EXISTS ${t}_ad AFTER DELETE ON $type '
        'BEGIN DELETE FROM $t WHERE rowid = old.rowid; END',
      );
    if (fresh) {
      db.execute(
        'INSERT INTO $t(rowid, $names) SELECT rowid, ${values(type)} '
        'FROM $type WHERE ${live(type)}',
      );
    }
  }
}

/// Removes the indexes and triggers, so files that leave this device carry
/// data only and open in any tool without our SQL functions.
void dropSearchIndex(Database db) {
  for (final type in searchColumns.keys) {
    final t = searchTable(type);
    for (final suffix in ['ai', 'au', 'ad']) {
      db.execute('DROP TRIGGER IF EXISTS ${t}_$suffix');
    }
    db.execute('DROP TABLE IF EXISTS $t');
  }
}

/// FTS5 query restricting [term] to [columns]; the trigram index only helps
/// terms of three or more characters, shorter ones scan the index text.
String? ftsQuery(List<String> columns, String term) => term.runes.length < 3
    ? null
    : '{${columns.join(' ')}} : "${term.replaceAll('"', '""')}"';
