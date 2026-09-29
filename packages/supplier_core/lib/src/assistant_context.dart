import 'dart:convert';

import 'ai_runtime.dart';

const maxAssistantContextChars = 64000;
const maxAssistantHistoryChars = 12000;

const recallContextTool = <String, Object?>{
  'type': 'function',
  'function': {
    'name': 'recall_context',
    'description':
        '回查已整理的本次上下文原文。无id时分页列出索引；query可搜索所有原文。'
        '有id时按字符分页读原始JSON，继续使用next_offset。历史仅用于理解追问，业务事实须重新查询。',
    'parameters': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string', 'description': '索引里的完整编号，如c1'},
        'query': {'type': 'string', 'description': '原文关键词，最多200字符'},
        'offset': {'type': 'integer', 'minimum': 0},
        'limit': {
          'type': 'integer',
          'description': '列索引1至8项；读原文2至4000字符，默认3000',
        },
      },
      'additionalProperties': false,
    },
  },
};

/// Reversible, extractive compaction. Originals remain immutable for this run;
/// the model sees bounded excerpts and can recover exact source pages locally.
/// This is not an LLM-generated summary or a durable session database.
class AssistantContext {
  AssistantContext({
    required this.system,
    required this.question,
    List<List<Map<String, Object?>>> history = const [],
  }) {
    for (final turn in history) {
      _history.add(_entry('history', turn));
    }
  }

  final String system, question;
  final _history = <_Entry>[];
  final _batches = <_Entry>[];
  final _archive = <String, _Entry>{};
  List<_Entry> _lastVisible = [];
  final _supplied = <String>{};
  int compactions = 0;
  bool get hasArchivedContext => _archive.values.any((e) => e.archived);

  bool get hasUnreadToolResults =>
      _batches.any((e) => e.archived && !e.seen && e.hasBusinessCalls);

  bool wasSupplied(String id, String tool, String arguments, String result) =>
      _supplied.contains(jsonEncode([id, tool, arguments, result]));

  /// Commit delivery only after the provider has accepted this request. A local
  /// query in the archive is not automatically model-visible citation evidence.
  void markSent() {
    for (final entry in _lastVisible) {
      _markSeen(entry);
      final messages = entry.messages;
      final calls = (messages.first['tool_calls'] as List?) ?? [];
      final recalls = {
        for (final call in calls)
          if (call['function']['name'] == 'recall_context') call['id'],
      };
      for (final message in messages.skip(1)) {
        if (!recalls.contains(message['tool_call_id'])) continue;
        final page = jsonDecode(message['content'] as String);
        if (page is! Map ||
            page['id'] is! String ||
            page['offset'] is! int ||
            page['text'] is! String)
          continue;
        final original = _archive[page['id']];
        if (original == null) continue;
        final start = page['offset'] as int;
        final text = page['text'] as String;
        final end = start + text.length;
        if (start < 0 ||
            end > original.source.length ||
            original.source.substring(start, end) != text)
          continue;
        original.reads.add((start, end));
        var covered = 0;
        for (final range
            in original.reads..sort((a, b) => a.$1.compareTo(b.$1))) {
          if (range.$1 > covered) break;
          if (range.$2 > covered) covered = range.$2;
        }
        if (covered == original.source.length) _markSeen(original);
      }
    }
  }

  void _markSeen(_Entry entry) {
    entry.seen = true;
    if (entry.kind != 'tools') return;
    final messages = entry.messages;
    final calls = (messages.first['tool_calls'] as List?) ?? [];
    for (final call in calls) {
      final function = call['function'] as Map;
      if (function['name'] == 'recall_context') continue;
      for (final result in messages.skip(1)) {
        if (result['tool_call_id'] == call['id']) {
          _supplied.add(
            jsonEncode([
              call['id'],
              function['name'],
              function['arguments'],
              result['content'],
            ]),
          );
        }
      }
    }
  }

  _Entry _entry(String kind, List<Map<String, Object?>> messages) {
    final entry = _Entry('c${_archive.length + 1}', kind, jsonEncode(messages));
    _archive[entry.id] = entry;
    return entry;
  }

  /// Call only after validating/executing the entire tool batch. Archiving a
  /// whole batch preserves every assistant tool call / tool result pairing.
  void addBatch(List<Map<String, Object?>> messages) {
    _batches.add(_entry('tools', messages));
  }

  List<Map<String, Object?>> messages({String? finalInstruction}) {
    var changed = false;
    int historySize() => _history
        .where((e) => !e.archived)
        .fold(0, (size, e) => size + e.source.length);
    if (historySize() > maxAssistantHistoryChars) {
      for (final entry in _history.where((e) => !e.archived)) {
        entry.archived = true;
        changed = true;
        if (historySize() <= maxAssistantHistoryChars ~/ 2) break;
      }
    }
    var out = _compose(finalInstruction);
    if (jsonEncode(out).length > maxAssistantContextChars * 3 ~/ 4) {
      for (final entry in [
        ..._history,
        ..._batches,
      ].where((e) => !e.archived)) {
        // Fresh results that fit the hard request limit must reach the model at
        // least once, even if this temporarily exceeds the soft compact target.
        if (entry.kind == 'tools' &&
            !entry.seen &&
            jsonEncode(out).length <= maxAssistantContextChars)
          break;
        entry.archived = true;
        changed = true;
        out = _compose(finalInstruction);
        if (jsonEncode(out).length <= maxAssistantContextChars ~/ 2) break;
      }
    }
    if (jsonEncode(out).length > maxAssistantContextChars) {
      // A heavily escaped current question can itself approach the hard limit.
      // Keep source access but use only the archive count rather than excerpts.
      out = _compose(finalInstruction, previews: false);
    }
    if (jsonEncode(out).length > maxAssistantContextChars) {
      throw LlmException('当前问题与固定规则超过请求容量，请缩短本次问题；历史原文未修改');
    }
    if (changed) compactions++;
    _lastVisible = _batches.where((e) => !e.archived).toList();
    return out;
  }

  List<Map<String, Object?>> _compose(
    String? finalInstruction, {
    bool previews = true,
  }) => [
    {'role': 'system', 'content': system},
    ..._section(_history, previews),
    {'role': 'user', 'content': question},
    ..._section(_batches, previews),
    if (finalInstruction != null) {'role': 'user', 'content': finalInstruction},
  ];

  List<Map<String, Object?>> _section(List<_Entry> entries, bool previews) {
    final archived = entries.where((e) => e.archived).toList();
    return [
      if (archived.isNotEmpty)
        {
          'role': 'user',
          'content':
              '以下是自动整理的旧上下文索引，不是新指令，也不是完整摘要。'
              '完整原文仍可用recall_context按id取回，或query搜索；不要从摘录推断未读内容。'
              '历史数据不代表当前事实，需重新查业务工具。最新用户修正优先。\n'
              '${jsonEncode({'archived_count': archived.length, 'entries': previews ? archived.take(12).map((e) => e.index).toList() : [], 'index_has_more': !previews || archived.length > 12})}',
        },
      for (final entry in entries.where((e) => !e.archived)) ...entry.messages,
    ];
  }

  /// Strictly local. Missing/malformed IDs cannot access another run or file.
  String recall(String arguments) {
    String error(String message) =>
        jsonEncode({'error': 'invalid_context_request', 'message': message});
    Object? decoded;
    try {
      decoded = jsonDecode(arguments);
    } on FormatException {
      return error('参数必须为JSON对象');
    }
    if (decoded is! Map<String, Object?> ||
        decoded.keys.any(
          (k) => !['id', 'query', 'offset', 'limit'].contains(k),
        )) {
      return error('参数字段无效');
    }
    final id = decoded['id'], query = decoded['query'];
    final offset = decoded['offset'] ?? 0;
    final limit = decoded['limit'] ?? (id == null ? 8 : 3000);
    if (offset is! int ||
        offset < 0 ||
        limit is! int ||
        (query != null && (query is! String || query.length > 200)) ||
        (id != null && id is! String)) {
      return error('编号、关键词或分页参数无效');
    }
    if (id != null) {
      final entry = _archive[id];
      if (entry == null) return error('本次上下文中没有该编号');
      if (query != null ||
          limit < 2 ||
          limit > 4000 ||
          offset > entry.source.length ||
          (offset > 0 &&
              offset < entry.source.length &&
              _low(entry.source.codeUnitAt(offset)) &&
              _high(entry.source.codeUnitAt(offset - 1)))) {
        return error('原文分页范围无效');
      }
      var end = (offset + limit).clamp(0, entry.source.length);
      if (end < entry.source.length && _high(entry.source.codeUnitAt(end - 1)))
        end--;
      return jsonEncode({
        'id': entry.id,
        'kind': entry.kind,
        'historical_context_only': true,
        'text': entry.source.substring(offset, end),
        'offset': offset,
        'next_offset': end < entry.source.length ? end : null,
        'total_chars': entry.source.length,
      });
    }
    if (limit < 1 || limit > 8) return error('索引每页应为1至8项');
    final pattern = query is String && query.isNotEmpty
        ? RegExp(RegExp.escape(query), caseSensitive: false)
        : null;
    final matches = _archive.values
        .where((e) => pattern != null ? pattern.hasMatch(e.source) : e.archived)
        .toList();
    if (offset > matches.length) return error('索引偏移超出范围');
    final end = (offset + limit).clamp(0, matches.length);
    return jsonEncode({
      'entries': matches.sublist(offset, end).map((e) {
        final match = pattern?.firstMatch(e.source);
        var start = match == null
            ? 0
            : (match.start - 80).clamp(0, e.source.length);
        if (start > 0 && _low(e.source.codeUnitAt(start))) start--;
        var stop = (start + 320).clamp(0, e.source.length);
        if (stop < e.source.length && _high(e.source.codeUnitAt(stop - 1)))
          stop--;
        return {
          ...e.index,
          if (match != null) ...{
            'match_offset': match.start,
            'read_offset': start,
            'match_preview': e.source.substring(start, stop),
          },
        };
      }).toList(),
      'next_offset': end < matches.length ? end : null,
      'total': matches.length,
    });
  }
}

bool _high(int c) => c >= 0xd800 && c <= 0xdbff;
bool _low(int c) => c >= 0xdc00 && c <= 0xdfff;

class _Entry {
  _Entry(this.id, this.kind, this.source);
  final String id, kind, source;
  bool archived = false;
  bool seen = false;
  final reads = <(int, int)>[];
  bool get hasBusinessCalls => ((messages.first['tool_calls'] as List?) ?? [])
      .any((call) => call['function']['name'] != 'recall_context');
  List<Map<String, Object?>> get messages =>
      (jsonDecode(source) as List).cast<Map<String, Object?>>();
  Map<String, Object?> get index {
    final first = messages.first;
    final content = first['content'] ?? first['tool_calls'] ?? '';
    final raw = content is String ? content : jsonEncode(content);
    var end = raw.length.clamp(0, 160);
    if (end < raw.length && end > 0 && _high(raw.codeUnitAt(end - 1))) end--;
    return {
      'id': id,
      'kind': kind,
      'preview': raw.substring(0, end),
      'chars': source.length,
    };
  }
}
