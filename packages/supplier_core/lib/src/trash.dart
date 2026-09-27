import 'ontology.dart';
import 'store.dart';

class DeletedRecord {
  DeletedRecord(this.type, this.id, this.data, this.at, this.by);
  final String type, id, at, by;
  final Map<String, Object?> data;
}

extension Trash on Store {
  /// Deleted records, most recently deleted first (the recycle bin).
  List<DeletedRecord> deletedRecords({int limit = 200}) {
    final all = [
      for (final type in entityTypes)
        for (final r in db.select(
          'SELECT id, updated_at, updated_by FROM $type WHERE deleted = 1 '
          'ORDER BY updated_at DESC LIMIT ?',
          [limit],
        ))
          DeletedRecord(
            type,
            r['id'] as String,
            get(type, r['id'] as String)!.data,
            r['updated_at'] as String,
            r['updated_by'] as String,
          ),
    ]..sort((a, b) => b.at.compareTo(a.at));
    return all.take(limit).toList();
  }

  /// How many live records point at [id], per link ("quotation.supplier_id":
  /// 5): what a delete would leave referring to a deleted record.
  Map<String, int> referencesTo(String type, String id) => {
    for (final l in links)
      if (l.to == type && l.from != type)
        if (db.select(
              'SELECT count(*) AS n FROM ${l.from} WHERE deleted = 0 AND '
              '${l.many ? "EXISTS (SELECT 1 FROM json_each(data,'\$.${l.field}') WHERE value = ?)" : "json_extract(data,'\$.${l.field}') = ?"}',
              [id],
            ).first['n']
            case final int n when n > 0)
          l.name: n,
  };
}

/// "5 条报价、1 个联系人" for [referencesTo]'s result.
String describeReferences(Map<String, int> refs) => [
  for (final MapEntry(key: link, value: n) in refs.entries)
    '$n 条${ontology[link.split('.').first]!.label}',
].join('、');
