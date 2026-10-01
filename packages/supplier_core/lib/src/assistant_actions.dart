import 'dart:convert';

import 'ai_runtime.dart';
import 'assistant_toolset.dart';
import 'ontology.dart';
import 'quotation.dart';
import 'store.dart';
import 'trash.dart';
import 'values.dart';

enum AssistantPermission { readOnly, confirmWrites }

Object? _freeze(Object? value) => switch (value) {
  Map value => Map<String, Object?>.unmodifiable({
    for (final key in (value.keys.cast<String>().toList()..sort()))
      key: _freeze(value[key]),
  }),
  List value => List<Object?>.unmodifiable(value.map(_freeze)),
  null || String() || bool() || num() => value,
  _ => throw const FormatException('Expected JSON values'),
};

Map<String, Object?> _map(Map<String, Object?> value) =>
    _freeze(value)! as Map<String, Object?>;

class AssistantActionPreview {
  AssistantActionPreview({
    required this.operation,
    required this.type,
    required this.id,
    required this.title,
    required Map<String, Object?> before,
    required Map<String, Object?> after,
    required Map<String, int> affectedReferences,
    required Map<String, Object?> referencedRecords,
    required this.version,
  }) : before = _map(before),
       after = _map(after),
       affectedReferences = Map.unmodifiable(affectedReferences),
       referencedRecords = _map(referencedRecords);

  final String operation, type, id, title;
  final int? version;
  final Map<String, Object?> before, after, referencedRecords;
  final Map<String, int> affectedReferences;
  Map<String, Object?> get changes => Map.unmodifiable({
    for (final key in {...before.keys, ...after.keys})
      if (jsonEncode(before[key]) != jsonEncode(after[key]))
        key: Map<String, Object?>.unmodifiable({
          'before': before[key],
          'after': after[key],
        }),
  });
}

/// Authority is supplied by the host. Model arguments never grant approval.
class AssistantAppTools implements AssistantToolset {
  AssistantAppTools(
    this.store, {
    required this.permission,
    required this.sessionId,
    this.approve,
    this.validateSession,
    this.onChanged,
  }) {
    if (sessionId.isEmpty || sessionId.length > 200) {
      throw ArgumentError.value(sessionId, 'sessionId');
    }
  }

  final Store store;
  final AssistantPermission permission;
  final String sessionId;
  final Future<bool> Function(AssistantActionPreview)? approve;
  final void Function()? validateSession, onChanged;

  /// Committed outcomes remain available after cancellation for the host UI.
  /// Exact prefix matching avoids treating session IDs as SQL wildcards.
  List<Map<String, Object?>> get appliedActions {
    final prefix = 'assistant_action:[${jsonEncode(sessionId)},';
    return List.unmodifiable([
      for (final row in store.db.select(
        'SELECT value FROM meta WHERE substr(key,1,length(?))=? ORDER BY key LIMIT 24',
        [prefix, prefix],
      ))
        _map(
          ((jsonDecode(row['value'] as String) as Map)['result'] as Map)
              .cast<String, Object?>(),
        ),
    ]);
  }

  static const _types = [
    'supplier',
    'contact',
    'product',
    'project',
    'project_item',
    'inquiry',
    'quotation',
  ];
  static const _operations = [
    'create_record',
    'update_record',
    'delete_record',
    'restore_record',
  ];
  static const _protectedFields = {
    'merged_into',
    'attachment_ids',
    'capture_mode',
  };

  @override
  List<Map<String, Object?>> get tools =>
      permission == AssistantPermission.readOnly
      ? const []
      : [
          for (final name in _operations)
            {
              'type': 'function',
              'function': {
                'name': name,
                'description':
                    'Propose a local business record change. The user must approve the concrete preview. Read the ontology for fields; decimals are strings. Administrative and attachment fields are forbidden.',
                'parameters': {
                  'type': 'object',
                  'additionalProperties': false,
                  'properties': {
                    'type': {'type': 'string', 'enum': _types},
                    if (name != 'create_record') 'id': {'type': 'string'},
                    if (name == 'create_record' || name == 'update_record')
                      'values': {'type': 'object'},
                  },
                  'required': [
                    'type',
                    if (name != 'create_record') 'id',
                    if (name == 'create_record' || name == 'update_record')
                      'values',
                  ],
                },
              },
            },
        ];

  void _check(AiCancellation cancellation) {
    cancellation.check();
    validateSession?.call();
    if (permission != AssistantPermission.confirmWrites) {
      throw const FormatException('Application writes are disabled');
    }
  }

  Map<String, Object?>? _receipt(String key, String args) {
    final rows = store.db.select('SELECT value FROM meta WHERE key=?', [key]);
    if (rows.isEmpty) return null;
    final receipt = jsonDecode(rows.single['value'] as String) as Map;
    if (receipt['arguments'] != args) {
      throw const FormatException(
        'Tool call ID already used with different arguments',
      );
    }
    // Preserve the exact model observation for checkpoint request equality.
    return (receipt['result'] as Map).cast<String, Object?>();
  }

  Map<String, Object?> _record(Record record) => {
    'type': record.type,
    'id': record.id,
    'version': record.version,
    'deleted': record.deleted,
    'data': record.data,
  };

  Map<String, Object?> _references(
    String type,
    String id,
    Map<String, Object?> data,
  ) {
    final result = <String, Object?>{};
    for (final link in links) {
      if (link.from == type) {
        final raw = data[link.field];
        final ids = link.many
            ? (raw as List? ?? const [])
            : [if (raw != null) raw];
        for (final targetId in ids) {
          final record = store.get(link.to, targetId as String);
          result['${link.to}:$targetId'] = record == null
              ? null
              : _record(record);
        }
      }
      if (link.to == type) {
        final condition = link.many
            ? "EXISTS (SELECT 1 FROM json_each(data,'\$.${link.field}') WHERE value=?)"
            : "json_extract(data,'\$.${link.field}')=?";
        for (final row in store.db.select(
          'SELECT id FROM ${link.from} WHERE deleted=0 AND $condition ORDER BY id',
          [id],
        )) {
          final record = store.get(link.from, row['id'] as String)!;
          result['${record.type}:${record.id}'] = _record(record);
        }
      }
    }
    return _map(result);
  }

  void _checkInquiry(String type, Map<String, Object?> data) {
    if (type != 'inquiry') return;
    for (final id in data['item_ids']! as List) {
      final item = store.get('project_item', id as String);
      if (item == null || item.data['project_id'] != data['project_id']) {
        throw const FormatException('Inquiry items must belong to its project');
      }
    }
  }

  @override
  Future<String> execute(
    String name,
    Map<String, Object?> arguments, {
    required String callId,
    required AiCancellation cancellation,
  }) async {
    _check(cancellation);
    if (!_operations.contains(name) || callId.isEmpty || callId.length > 200) {
      throw const FormatException('Invalid action or call ID');
    }
    final args = _map(arguments);
    final editing = name == 'create_record' || name == 'update_record';
    final creating = name == 'create_record';
    final keys = {'type', if (!creating) 'id', if (editing) 'values'};
    if (args.length != keys.length ||
        !keys.containsAll(args.keys) ||
        !_types.contains(args['type'])) {
      throw const FormatException('Invalid action arguments');
    }
    final type = args['type']! as String;
    final canonical = jsonEncode({'name': name, 'arguments': args});
    final receiptKey = 'assistant_action:${jsonEncode([sessionId, callId])}';
    final prior = _receipt(receiptKey, canonical);
    if (prior != null) return jsonEncode(prior);
    final id = creating ? newUuid() : requireUuid(args['id'], 'id');
    final previous = creating ? null : store.get(type, id);
    if (!creating &&
        (previous == null || previous.deleted != (name == 'restore_record'))) {
      throw const FormatException('Record unavailable for this action');
    }
    Map<String, Object?> data = previous?.data ?? {};
    if (editing) {
      final values = args['values'];
      if (values is! Map<String, Object?> ||
          values.isEmpty ||
          values.keys.any(
            (key) =>
                !payloadFields(type).contains(key) ||
                _protectedFields.contains(key),
          )) {
        throw const FormatException(
          'Unknown, protected, or empty record fields',
        );
      }
      data = validatePayload(type, {
        for (final field in payloadFields(type)) field: null,
        if (type == 'supplier') 'aliases': <String>[],
        if (type == 'supplier') 'categories': <String>[],
        if (type == 'inquiry') ...{
          'item_ids': <String>[],
          'supplier_ids': <String>[],
        },
        if (type == 'quotation') 'capture_mode': 'standard',
        ...?previous?.data,
        ...values,
      });
    }
    data = _map(data);
    _checkInquiry(type, data);
    final refs = _references(type, id, data);
    final preview = AssistantActionPreview(
      operation: name,
      type: type,
      id: id,
      title:
          '$name ${ontology[type]!.label}: ${data['name'] ?? data['title'] ?? data['code'] ?? id}',
      before: previous?.data ?? {},
      after: data,
      version: previous?.version,
      affectedReferences: name == 'delete_record'
          ? store.referencesTo(type, id)
          : {},
      referencedRecords: refs,
    );
    if (approve == null)
      throw const FormatException('Approval interface unavailable');
    final accepted = await cancellation.wait(approve!(preview));
    _check(cancellation);
    if (!accepted)
      return jsonEncode({'status': 'denied', 'type': type, 'id': id});
    var didApply = false;
    final result = store.transaction(() {
      _check(cancellation);
      final duplicate = _receipt(receiptKey, canonical);
      if (duplicate != null) return duplicate;
      final current = store.get(type, id);
      if (jsonEncode(current == null ? null : _record(current)) !=
              jsonEncode(previous == null ? null : _record(previous)) ||
          jsonEncode(_references(type, id, data)) != jsonEncode(refs)) {
        throw const FormatException(
          'Approval expired: records changed; request a new preview',
        );
      }
      _checkInquiry(type, data);
      switch (name) {
        case 'create_record':
          store.save(type, data, newId: id);
        case 'update_record':
          // The exact null-clearing fields were shown in the approved preview.
          store.save(type, data, id: id, allowClear: true);
        case 'delete_record':
          store.delete(type, id);
        case 'restore_record':
          store.restore(type, id);
      }
      final saved = store.get(type, id)!;
      final result = <String, Object?>{
        'status': 'applied',
        'type': type,
        'id': id,
        'record': {
          'id': id,
          for (final field in ['name', 'title'])
            if (saved.data[field] case final String value)
              field: value.length <= 200 ? value : value.substring(0, 200),
        },
        'record_complete': false,
        'version': saved.version,
        'deleted': saved.deleted,
      };
      store.db.execute('INSERT INTO meta(key,value) VALUES (?,?)', [
        receiptKey,
        jsonEncode({'arguments': canonical, 'result': result}),
      ]);
      didApply = true;
      return result;
    });
    // The committed receipt is authoritative even if the UI observer fails.
    if (didApply) {
      try {
        onChanged?.call();
      } catch (_) {
        /* Persisted action remains applied. */
      }
    }
    return jsonEncode(result);
  }
}
