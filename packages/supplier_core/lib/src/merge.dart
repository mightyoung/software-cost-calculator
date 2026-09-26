import 'dart:convert';

import 'store.dart';
import 'values.dart';

/// Entity types whose duplicates can be merged.
const mergeableTypes = {'supplier', 'product'};

const _maxHops = 64;

/// Merging never deletes: the duplicate keeps its row with `merged_into`
/// pointing at the record it was merged into. References that arrive later
/// from other devices can then still be followed and redirected, instead of
/// dangling at a deleted record.
extension Merge on Store {
  /// The record [id] finally resolves to (itself when not merged). In a
  /// merge cycle, which two devices can create by merging in opposite
  /// directions, the smallest id in the cycle is the root.
  String mergeRoot(String type, String id) {
    final seen = <String>[];
    var current = id;
    while (seen.length < _maxHops) {
      final at = seen.indexOf(current);
      if (at >= 0) {
        return (seen.sublist(at)..sort()).first;
      }
      seen.add(current);
      final next = get(type, current)?.data['merged_into'] as String?;
      if (next == null) return current;
      current = next;
    }
    return current;
  }

  /// Merges duplicate [fromId] into [intoId] and redirects every live
  /// reference. A merged supplier's name and aliases become aliases of the
  /// record it was merged into.
  void mergeInto(String type, String fromId, String intoId) => transaction(() {
    if (!mergeableTypes.contains(type)) invalid('type', 'cannot be merged');
    final from = get(type, fromId);
    final into = get(type, intoId);
    if (from == null || from.deleted || into == null || into.deleted) {
      invalid('id', 'record does not exist');
    }
    if (from.data['merged_into'] != null) {
      invalid('merged_into', 'already merged');
    }
    final root = mergeRoot(type, intoId);
    if (root == fromId) invalid('merged_into', 'cannot merge into itself');
    if (type == 'supplier') {
      final target = get(type, root)!.data;
      final aliases = <String>{
        ...(target['aliases']! as List).cast<String>(),
        from.data['name']! as String,
        ...(from.data['aliases']! as List).cast<String>(),
      }..remove(target['name']);
      save(type, {...target, 'aliases': aliases.take(20).toList()}, id: root);
    }
    save(type, {...from.data, 'merged_into': root}, id: fromId);
    redirectMerged();
  });

  /// Repairs merges (see [_repairMerges]), then points every live reference to a merged
  /// record at its root. Runs after each merge and each import, so records
  /// from other devices follow merges made here. Every device computes the
  /// same result, so exchanging converges. Returns how many records changed.
  int redirectMerged() => transaction(() {
    var changed = 0;
    for (final type in mergeableTypes) {
      changed += _repairMerges(type);
    }
    for (final MapEntry(key: type, value: fields) in references.entries) {
      final mergeable = {
        for (final MapEntry(key: field, value: target) in fields.entries)
          if (mergeableTypes.contains(target) && field != 'merged_into')
            field: target,
      };
      if (mergeable.isEmpty) continue;
      final where = [
        for (final MapEntry(key: field, value: target) in mergeable.entries)
          "json_extract(data,'\$.$field') IN (SELECT id FROM $target "
              "WHERE json_extract(data,'\$.merged_into') IS NOT NULL)",
      ].join(' OR ');
      for (final r in db.select(
        'SELECT id, data FROM $type WHERE deleted = 0 AND ($where)',
      )) {
        final data = Map.of(
          jsonDecode(r['data'] as String) as Map<String, Object?>,
        );
        for (final MapEntry(key: field, value: target) in mergeable.entries) {
          final id = data[field] as String?;
          if (id != null) data[field] = mergeRoot(target, id);
        }
        save(type, data, id: r['id'] as String);
        changed++;
      }
    }
    for (final MapEntry(key: type, value: fields) in listReferences.entries) {
      for (final MapEntry(key: field, value: target) in fields.entries) {
        if (!mergeableTypes.contains(target)) continue;
        for (final r in db.select(
          "SELECT o.id, o.data FROM $type o WHERE o.deleted = 0 AND EXISTS ("
          "SELECT 1 FROM json_each(o.data,'\$.$field') j JOIN $target t "
          "ON t.id = j.value WHERE json_extract(t.data,'\$.merged_into') "
          'IS NOT NULL)',
        )) {
          final data = Map.of(
            jsonDecode(r['data'] as String) as Map<String, Object?>,
          );
          data[field] = [
            for (final id in data[field]! as List)
              mergeRoot(target, id as String),
          ];
          save(type, data, id: r['id'] as String);
          changed++;
        }
      }
    }
    return changed;
  });

  /// Clears `merged_into` where it no longer holds: on a record merged into
  /// one deleted since (on another device), and on the root of each cycle.
  int _repairMerges(String type) {
    var changed = 0;
    for (final r in db.select(
      "SELECT id, data FROM $type WHERE deleted = 0 "
      "AND json_extract(data,'\$.merged_into') IS NOT NULL",
    )) {
      final id = r['id'] as String;
      final data = jsonDecode(r['data'] as String) as Map<String, Object?>;
      final target = get(type, data['merged_into']! as String);
      final dangling = target == null || target.deleted;
      if (!dangling && mergeRoot(type, id) != id) continue;
      save(type, {...data, 'merged_into': null}, id: id);
      changed++;
    }
    return changed;
  }
}
