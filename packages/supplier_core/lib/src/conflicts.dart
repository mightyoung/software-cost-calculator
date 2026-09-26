import 'dart:convert';

import 'store.dart';
import 'values.dart';

/// One side of a conflict: a value some device wrote.
class FieldValue {
  FieldValue(this.value, this.device, this.at);
  final Object? value;
  final String device, at;
}

/// Two devices changed the same field starting from the same value. The
/// merge kept the later edit; the user decides which value stays. [first]
/// is the earlier of the two edits.
class FieldConflict {
  FieldConflict(
    this.entity,
    this.entityId,
    this.field,
    this.first,
    this.second,
  );
  final String entity, entityId, field;
  final FieldValue first, second;
}

extension Conflicts on Store {
  /// Concurrent edits nobody has settled yet: two change-log entries for
  /// the same field with the same old value and different new values, from
  /// different devices, with no later change of that field. Consecutive
  /// edits never match, because the second one starts from the first's
  /// result. Entries that only mark a resolution (old equals new) are
  /// ignored.
  List<FieldConflict> openConflicts() => [
    for (final r in db.select(
      'SELECT a.entity, a.entity_id, a.field, '
      'a.new AS a_new, a.device AS a_device, a.at AS a_at, '
      'b.new AS b_new, b.device AS b_device, b.at AS b_at '
      'FROM change_log a JOIN change_log b '
      'ON b.entity_id = a.entity_id AND b.field = a.field '
      'AND (b.at, b.id) > (a.at, a.id) '
      'AND b.old IS a.old AND b.new <> a.new AND b.device <> a.device '
      "WHERE a.field NOT LIKE '(%' AND a.old <> a.new AND b.old <> b.new "
      'AND NOT EXISTS (SELECT 1 FROM change_log c '
      'WHERE c.entity_id = a.entity_id AND c.field = a.field '
      'AND c.at > a.at AND c.at > b.at) '
      'ORDER BY max(a.at, b.at) DESC',
    ))
      if (!(get(r['entity'] as String, r['entity_id'] as String)?.deleted ??
          true))
        FieldConflict(
          r['entity'] as String,
          r['entity_id'] as String,
          r['field'] as String,
          FieldValue(
            jsonDecode(r['a_new'] as String),
            r['a_device'] as String,
            r['a_at'] as String,
          ),
          FieldValue(
            jsonDecode(r['b_new'] as String),
            r['b_device'] as String,
            r['b_at'] as String,
          ),
        ),
  ];

  /// Keeps [value] for the conflicting field. Either way a new log entry is
  /// written, which settles the conflict here and, after exchange, on every
  /// other device.
  void resolveConflict(FieldConflict c, Object? value) => transaction(() {
    final record = get(c.entity, c.entityId);
    if (record == null || record.deleted)
      invalid('id', 'record does not exist');
    if (jsonEncode(record.data[c.field]) == jsonEncode(value)) {
      markResolved(c.entity, c.entityId, c.field);
    } else {
      save(
        c.entity,
        {...record.data, c.field: value},
        id: c.entityId,
        allowClear: true,
      );
    }
  });
}
