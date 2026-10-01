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

/// A bounded local tool observation, with explicit model-delivery status.
class AssistantObservation {
  const AssistantObservation({
    required this.callId,
    required this.tool,
    required this.arguments,
    required this.result,
    required this.round,
    this.providedToModel = true,
  });
  final String callId, tool, arguments, result;
  final int round;
  final bool providedToModel;
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
    'provided_to_model': providedToModel,
  };
}

/// Source positions from successful web tools, never URLs invented in prose.
class AssistantSource {
  const AssistantSource({
    required this.url,
    required this.title,
    required this.fetchedAt,
    this.excerpt = '',
    this.truncated = false,
  });
  final String url, title, fetchedAt, excerpt;
  final bool truncated;

  Map<String, Object?> toJson() => {
    'url': url,
    'title': title,
    'fetched_at': fetchedAt,
    'excerpt': excerpt,
    'truncated': truncated,
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
    this.contextCompactions,
  ) : observations = List.unmodifiable(observations),
      warnings = List.unmodifiable(warnings);

  factory AssistantAnswer.fromRun(
    String answer,
    List<AssistantObservation> observations, {
    required int modelCalls,
    required Duration elapsed,
    int contextCompactions = 0,
    bool Function(AssistantObservation)? wasSupplied,
  }) {
    if (wasSupplied != null) {
      observations = [
        for (final o in observations)
          AssistantObservation(
            callId: o.callId,
            tool: o.tool,
            arguments: o.arguments,
            result: o.result,
            round: o.round,
            providedToModel: wasSupplied(o),
          ),
      ];
    }
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
        if (observations.any((o) => !o.providedToModel))
          '部分查询结果已归档但尚未完整送达模型；本次回答可能不完整，请核对查询依据或继续缩小查询。',
      ],
      unsupported,
      modelCalls,
      elapsed,
      contextCompactions,
    );
  }

  final String text;
  final List<AssistantObservation> observations;
  List<AssistantSource> get sources {
    final found = <String, AssistantSource>{};
    for (final observation in observations) {
      if (!observation.providedToModel ||
          observation.failed ||
          !const {
            'web_search',
            'web_fetch',
            'web_extract',
          }.contains(observation.tool)) {
        continue;
      }
      final data = jsonDecode(observation.result);
      if (data is! Map || data['sources'] is! List) continue;
      for (final source in (data['sources'] as List).whereType<Map>()) {
        final url = source['url'];
        final title = source['title'];
        final at = source['fetched_at'];
        if (url is! String ||
            url.length > 2048 ||
            title is! String ||
            at is! String)
          continue;
        final uri = Uri.tryParse(url);
        if (uri == null ||
            uri.scheme != 'https' ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty)
          continue;
        found[url] = AssistantSource(
          url: url,
          title: title.length > 200 ? title.substring(0, 200) : title,
          fetchedAt: at,
          excerpt: source['excerpt'] is String
              ? (source['excerpt'] as String).substring(
                  0,
                  (source['excerpt'] as String).length.clamp(0, 500),
                )
              : '',
          truncated: source['truncated'] == true,
        );
        if (found.length >= 24) return List.unmodifiable(found.values);
      }
    }
    return List.unmodifiable(found.values);
  }

  final List<String> warnings;
  final int unverifiedReferences, modelCalls;
  final Duration elapsed;
  final int contextCompactions;

  Map<String, Object?> toJson() => {
    'text': text,
    'observations': [for (final o in observations) o.toJson()],
    'sources': [for (final source in sources) source.toJson()],
    'warnings': warnings,
    'unverified_references': unverifiedReferences,
    'model_calls': modelCalls,
    'elapsed_ms': elapsed.inMilliseconds,
    'context_compactions': contextCompactions,
  };
}

// Read only documented identity positions. UUIDs buried in notes, clauses,
// evidence text, failed results or call arguments cannot certify a record.
void _collectRecords(
  AssistantObservation observation,
  Map<String, String> records,
) {
  final data = jsonDecode(observation.result);
  if (!observation.providedToModel || observation.failed || data == null)
    return;
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
    case 'create_record' || 'update_record' || 'restore_record':
      if (data is Map &&
          const {'applied', 'already_applied'}.contains(data['status'])) {
        final row = data['record'];
        if (row is Map && row['data'] is Map) {
          add(data['type'] as String?, {
            ...(row['data'] as Map),
            'id': row['id'],
          });
        } else {
          add(data['type'] as String?, row);
        }
      }
  }
}
