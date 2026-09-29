import 'dart:convert';

import 'ontology.dart';

/// Only the structured record marker is eligible for a record link.
final recordRef = RegExp(
  r'\[\[(\w+):([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\|([^\]]+)\]\]',
);

// Models may escape the delimiter inside Markdown table cells. Accept exactly
// one backslash here, before provenance checks; public recordRef stays strict.
final _tableRecordRef = RegExp(
  r'\[\[(\w+):([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\\\|([^\]]+)\]\]',
);

/// A bounded tool observation actually supplied to the model, not reasoning.
class AssistantObservation {
  const AssistantObservation({
    required this.callId,
    required this.tool,
    required this.arguments,
    required this.result,
    required this.round,
  });
  final String callId, tool, arguments, result;
  final int round;
  bool get failed {
    final data = jsonDecode(result);
    return data is Map && data['error'] != null;
  }

  Map<String, Object?> toJson() => {
    'call_id': callId,
    'tool': tool,
    'arguments': arguments,
    'result': result,
    'round': round,
    'failed': failed,
  };
}

/// A local evidence packet. Record provenance is not a truth score for prose.
class AssistantAnswer {
  AssistantAnswer._(
    this.text,
    List<AssistantObservation> observations,
    List<String> warnings,
    this.unverifiedReferences,
    this.modelCalls,
    this.elapsed,
  ) : observations = List.unmodifiable(observations),
      warnings = List.unmodifiable(warnings);

  factory AssistantAnswer.fromRun(
    String answer,
    List<AssistantObservation> observations, {
    required int modelCalls,
    required Duration elapsed,
  }) {
    final records = <String, String>{};
    for (final observation in observations) {
      _collectRecords(observation, records);
    }
    var unsupported = 0;
    final normalized = answer.replaceAllMapped(
      _tableRecordRef,
      (match) => '[[${match[1]}:${match[2]}|${match[3]}]]',
    );
    final text = normalized.replaceAllMapped(recordRef, (match) {
      final name = records['${match[1]}:${match[2]}'];
      if (name == null) {
        unsupported++;
        final label = match[3]!.replaceAll(RegExp(r'[\[\]]'), '');
        return '$label（未核验）';
      }
      return '[[${match[1]}:${match[2]}|$name]]';
    });
    return AssistantAnswer._(
      text,
      observations,
      [
        if (observations.isEmpty) '本次回答没有查询本机数据，业务结论尚无查询依据。',
        if (unsupported > 0) '$unsupported 处记录引用未出现在本次查询结果中，已取消链接，请核对。',
        if (observations.any((o) => o.failed)) '执行中有工具查询失败，请展开查询依据核对。',
      ],
      unsupported,
      modelCalls,
      elapsed,
    );
  }

  final String text;
  final List<AssistantObservation> observations;
  final List<String> warnings;
  final int unverifiedReferences, modelCalls;
  final Duration elapsed;

  Map<String, Object?> toJson() => {
    'text': text,
    'observations': [for (final o in observations) o.toJson()],
    'warnings': warnings,
    'unverified_references': unverifiedReferences,
    'model_calls': modelCalls,
    'elapsed_ms': elapsed.inMilliseconds,
  };
}

// Read only documented identity positions. UUIDs buried in notes, clauses,
// evidence text, failed results or call arguments cannot certify a record.
void _collectRecords(
  AssistantObservation observation,
  Map<String, String> records,
) {
  final data = jsonDecode(observation.result);
  if (observation.failed || data == null) return;
  final args = jsonDecode(observation.arguments) as Map;
  void add(String? type, Object? row, {String idField = 'id'}) {
    if (type == null || !ontology.containsKey(type) || row is! Map) return;
    final id = row[idField];
    if (id is! String) return;
    final rawName = row['name'] ?? row['title'] ?? ontology[type]!.label;
    final name = '$rawName'.replaceAll(RegExp(r'[\[\]|\r\n]'), ' ').trim();
    records['$type:$id'] = name.isEmpty ? ontology[type]!.label : name;
  }

  void rows(String? type, Object? values, {String idField = 'id'}) {
    if (values is List) {
      for (final row in values) add(type, row, idField: idField);
    }
  }

  switch (observation.tool) {
    case 'get':
      add(args['type'] as String?, data);
    case 'search':
      rows(args['type'] as String?, data);
    case 'query':
      if (data is Map) rows(args['type'] as String?, data['rows']);
    case 'related':
      final link = links.where((l) => l.name == args['link']).firstOrNull;
      if (data is Map) rows(link?.from, data['rows']);
    case 'compare_quotes':
      if (data is List) {
        for (final group in data.whereType<Map>())
          rows('quotation', group['quotes']);
      }
    case 'quote_options':
      rows('quotation', data);
    case 'project_budget':
      if (data is Map) rows('project_item', data['lines']);
    case 'match_item':
      if (data is Map)
        rows('product', data['candidates'], idField: 'product_id');
    case 'inquiry_matrix':
      if (data is Map) {
        rows('supplier', data['suppliers']);
        rows('project_item', data['rows'], idField: 'item_id');
        if (data['rows'] case final List values) {
          for (final row in values.whereType<Map>()) {
            rows('quotation', row['quotes'], idField: 'quotation_id');
          }
        }
      }
  }
}
