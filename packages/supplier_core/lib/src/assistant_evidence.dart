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

  /// The answer to show. The model's own reply is the answer; only runs that
  /// reached the procurement-evidence tools are replaced by the application
  /// report, because there prices, models and compliance verdicts must come
  /// from verified tool results, never from free text.
  AssistantAnswer finalAnswer({String procurementReport = ''}) {
    if (procurementReport.isNotEmpty ||
        observations.any((o) => o.tool.startsWith('procurement_'))) {
      return verifiedReport(procurementReport: procurementReport);
    }
    if (!observations.any((o) => o.tool.startsWith('web_'))) return this;
    return AssistantAnswer.fromRun(
      '$text\n\n（网页与搜索内容仅是外部线索，未经逐字段核验，不等于已确认的价格、型号或合格结论。）',
      observations,
      modelCalls: modelCalls,
      elapsed: elapsed,
      contextCompactions: contextCompactions,
    );
  }

  /// Application-owned output. Model prose is deliberately not consumed.
  AssistantAnswer verifiedReport({String procurementReport = ''}) {
    final parts = <String>[];
    if (procurementReport.isNotEmpty) parts.add(procurementReport);
    final records = <String, String>{};
    final facts = <String>[];
    for (final observation in observations) {
      _collectRecords(observation, records);
      if (!observation.providedToModel || observation.failed) continue;
      if (!const {
        'get',
        'query',
        'search',
        'related',
        'compare_quotes',
        'quote_options',
        'project_budget',
        'data_quality',
        'inquiry_matrix',
        'match_item',
        'spec_classes',
      }.contains(observation.tool)) {
        continue;
      }
      final data = _displayFacts(jsonDecode(observation.result));
      final detail = const JsonEncoder.withIndent('  ').convert(data);
      facts.add(
        '${observation.tool}\n${detail.length > 2000 ? '${detail.substring(0, 2000)}\n（展示已截断，请展开工具实际结果查看完整内容）' : detail}',
      );
    }
    if (records.isNotEmpty) {
      parts.add(
        [
          '本机已读取或已确认保存的记录：',
          for (final entry in records.entries.take(12))
            '[[${entry.key}|${entry.value.replaceAll(RegExp(r'[\[\]\r\n]'), ' ')}]]',
          if (records.length > 12) '仅展示前 12 条，请展开实际工具结果。',
        ].join('\n'),
      );
    }
    if (facts.isNotEmpty) {
      parts.add('本机查询结果（保留原业务口径）：\n${facts.take(4).join('\n\n')}');
      if (facts.length > 4) parts.add('还有查询结果未展开，请查看工具实际结果。');
    }
    if (parts.isEmpty) {
      parts.add('本次没有取得可核验的采购候选或本机查询结果，不能确认物料、价格或技术符合性。请提供项目和技术要求，再查询来源。');
    }
    if (observations.any((o) => o.tool.startsWith('web_')) &&
        procurementReport.isEmpty) {
      parts.add('网页和搜索摘要仅是发现线索；尚未形成逐字段核验的可导入采购候选。');
    }
    if (observations.any((o) {
      if (!o.providedToModel || !o.tool.startsWith('web_')) return false;
      final result = jsonDecode(o.result);
      return result is Map && result['error'] == '用户拒绝此联网请求，尚未发送';
    })) {
      parts.add('用户拒绝联网请求，未查询网络。');
    }
    if (observations.any((o) => o.tool == 'open_page' && !o.failed)) {
      parts.add('已请求打开对应页面，请在页面内继续操作。');
    }
    return AssistantAnswer.fromRun(
      parts.join('\n\n'),
      observations,
      modelCalls: modelCalls,
      elapsed: elapsed,
      contextCompactions: contextCompactions,
    );
  }

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

Object? _displayFacts(Object? value, [int depth = 0]) {
  if (depth > 8) return '（更深层明细请查看实际工具结果）';
  if (value is Map) {
    return {
      for (final entry in value.entries)
        if (entry.key != 'id' &&
            !(entry.key as String).endsWith('_id') &&
            !(entry.key as String).endsWith('_ids'))
          entry.key: _displayFacts(entry.value, depth + 1),
    };
  }
  if (value is List)
    return [for (final v in value) _displayFacts(v, depth + 1)];
  return value;
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
