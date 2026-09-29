// Offline contract replay, NOT a measurement of a real model's accuracy.
// Run: dart run tool/assistant_eval.dart
import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';

import '../test/fixtures.dart' as fixtures;

/// Expected tool selection, exact arguments and selected JSON result fields.
class ExpectedObservation {
  const ExpectedObservation(
    this.tool,
    this.arguments,
    this.fields, {
    this.failed = false,
  });
  final String tool;
  final Map<String, Object?> arguments;
  final Map<String, Object?> fields;
  final bool failed;
}

class EvalCase {
  const EvalCase({
    required this.id,
    required this.question,
    required this.replies,
    required this.observations,
    required this.answerContains,
    this.references = const [],
    this.unverifiedReferences = 0,
  });
  final String id, question;
  final List<Map<String, Object?>> replies;
  final List<ExpectedObservation> observations;
  final List<String> answerContains, references;
  final int unverifiedReferences;
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is List) return value.map(_canonical).toList();
  return value;
}

bool _equal(Object? a, Object? b) =>
    jsonEncode(_canonical(a)) == jsonEncode(_canonical(b));

// Scripted decimal tokens must not match inside signed/exponent expressions.
// This is lexical contract checking, not natural-language semantic grading.
bool _containsAnswerToken(String text, String token) {
  final numeric = RegExp(r'[0-9.]');
  final numericExpression = RegExp(r'[0-9.eE+−-]');
  for (final match in RegExp(RegExp.escape(token)).allMatches(text)) {
    if (token.isEmpty) return false;
    if (numeric.hasMatch(token[0]) &&
        match.start > 0 &&
        numericExpression.hasMatch(text[match.start - 1]))
      continue;
    if (numeric.hasMatch(token[token.length - 1]) &&
        match.end < text.length &&
        numericExpression.hasMatch(text[match.end]))
      continue;
    return true;
  }
  return false;
}

Object? _field(Object? value, String path) {
  for (final key in path.split('.')) {
    if (value is Map && value.containsKey(key)) {
      value = value[key];
    } else if (value is List &&
        int.tryParse(key) != null &&
        int.parse(key) >= 0 &&
        int.parse(key) < value.length) {
      value = value[int.parse(key)];
    } else {
      return const {'missing': true};
    }
  }
  return value;
}

/// Independently grade captured evidence; no LLM judge and no external calls.
/// Public so tests can inject deliberately wrong traces as negative controls.
Map<String, Object?> gradeAssistantCase(
  EvalCase task, {
  required String text,
  required List<Map<String, Object?>> observations,
  required int unverifiedReferences,
  required bool readOnly,
  required bool wireMatchesEvidence,
}) {
  final tools =
      observations.length == task.observations.length &&
      List.generate(
        observations.length,
        (i) => observations[i]['tool'] == task.observations[i].tool,
      ).every((v) => v);
  final arguments =
      observations.length == task.observations.length &&
      List.generate(
        observations.length,
        (i) => _equal(
          observations[i]['arguments'],
          task.observations[i].arguments,
        ),
      ).every((v) => v);
  final fields =
      observations.length == task.observations.length &&
      List.generate(observations.length, (i) {
        final expected = task.observations[i];
        final got = observations[i];
        final result = got['result'];
        return got['failed'] == expected.failed &&
            (!expected.failed ||
                (result is Map && '${result['error'] ?? ''}'.isNotEmpty)) &&
            expected.fields.entries.every(
              (e) => _equal(_field(result, e.key), e.value),
            );
      }).every((v) => v);
  final references = [
    for (final match in recordRef.allMatches(text))
      '${match.group(1)}:${match.group(2)}',
  ]..sort();
  final expectedReferences = [...task.references]..sort();
  final checks = {
    'tool_selection': tools,
    'key_arguments': arguments,
    'result_fields': fields,
    'references':
        _equal(references, expectedReferences) &&
        unverifiedReferences == task.unverifiedReferences,
    'completion':
        text.trim().isNotEmpty &&
        task.answerContains.every((token) => _containsAnswerToken(text, token)),
    'read_only': readOnly,
    'evidence_matches_model_input': wireMatchesEvidence,
  };
  return {
    'id': task.id,
    'question': task.question,
    'pass': checks.values.every((v) => v),
    'checks': checks,
    'answer': text,
    'references': references,
    'unverified_reference_count': unverifiedReferences,
    'observations': observations,
  };
}

Map<String, Object?> _call(String tool, Map<String, Object?> args, int id) => {
  'role': 'assistant',
  'content': null,
  'tool_calls': [
    {
      'id': 'call_$id',
      'type': 'function',
      'function': {'name': tool, 'arguments': jsonEncode(args)},
    },
  ],
};

Map<String, Object?> _answer(String text) => {
  'role': 'assistant',
  'content': text,
};

List<EvalCase> _cases(Store store) {
  final supplier = store.save('supplier', fixtures.supplier('评测供应商'));
  final product = store.save('product', fixtures.product('评测泵'));
  final project = store.save('project', fixtures.project('EVAL'));
  final quote = store.save(
    'quotation',
    fixtures.quotation(supplier, product, project, '999999999999.999999'),
  );
  store.save(
    'quotation',
    fixtures.quotation(supplier, product, project, '999999999999.999998'),
  );
  for (var i = 0; i < 3; i++) {
    store.save(
      'project_item',
      fixtures.item(project, 'other', name: '评测明细$i', cost: '2'),
    );
  }
  for (final confirmed in [true, false]) {
    store.save('product_param', {
      'product_id': product,
      'property': confirmed ? 'cpu.cores' : 'memory.capacity',
      'value': {'v': '8'},
      'cond': null,
      'source': 'manual',
      'evidence': null,
      'attachment_id': null,
      'confirmed': confirmed,
      'dict_version': 1,
    });
  }
  const missing = '00000000-0000-4000-8000-000000000000';
  final exact = <String, Object?>{
    'type': 'quotation',
    'where': [
      {'field': 'price', 'op': 'eq', 'value': '999999999999.999999'},
    ],
  };
  final budget = <String, Object?>{'project_id': project, 'limit': 1};
  final boolean = <String, Object?>{
    'type': 'product_param',
    'where': [
      {'field': 'confirmed', 'op': 'eq', 'value': true},
    ],
  };
  final badBoolean = <String, Object?>{
    'type': 'product_param',
    'where': [
      {'field': 'confirmed', 'op': 'eq', 'value': 'true'},
    ],
  };
  final missingBudget = <String, Object?>{'project_id': missing};
  final empty = <String, Object?>{
    'type': 'supplier',
    'where': [
      {'field': 'name', 'op': 'eq', 'value': '不存在的供应商'},
    ],
  };
  final write = <String, Object?>{'type': 'supplier', 'id': supplier};
  return [
    EvalCase(
      id: 'exact_decimal',
      question: '查报价恰好为 999999999999.999999 的记录并引用。',
      replies: [
        _call('query', exact, 1),
        _answer('[[quotation:$quote|报价]] 金额 999999999999.999999。'),
      ],
      observations: [
        ExpectedObservation('query', exact, {
          'total': 1,
          'rows.0.price': '999999999999.999999',
          'rows.0.id': quote,
        }),
      ],
      answerContains: ['999999999999.999999'],
      references: ['quotation:$quote'],
    ),
    EvalCase(
      id: 'full_budget_bounded_details',
      question: '项目 $project 总成本是多少？只展示一条明细。',
      replies: [
        _call('project_budget', budget, 1),
        _answer('总成本 6；共 3 条，明细仅展示 1 条，已截断。'),
      ],
      observations: [
        ExpectedObservation('project_budget', budget, {
          'cost': '6',
          'total': 3,
          'returned': 1,
          'truncated': true,
        }),
      ],
      answerContains: ['总成本 6', '截断'],
    ),
    EvalCase(
      id: 'boolean_filter',
      question: '查询已确认的产品参数。',
      replies: [_call('query', boolean, 1), _answer('已确认参数 1 条。')],
      observations: [
        ExpectedObservation('query', boolean, {
          'total': 1,
          'rows.0.confirmed': true,
        }),
      ],
      answerContains: ['1 条'],
    ),
    EvalCase(
      id: 'invalid_argument_recovery',
      question: '查询已确认参数，如果参数类型有误请修正后重试。',
      replies: [
        _call('query', badBoolean, 1),
        _call('query', boolean, 2),
        _answer('已修正参数类型，已确认参数 1 条。'),
      ],
      observations: [
        ExpectedObservation('query', badBoolean, {}, failed: true),
        ExpectedObservation('query', boolean, {
          'total': 1,
          'rows.0.confirmed': true,
        }),
      ],
      answerContains: ['已修正', '1 条'],
    ),
    EvalCase(
      id: 'unsupported_reference',
      question: '不查询，直接引用供应商 $supplier。',
      replies: [_answer('[[supplier:$supplier|评测供应商]]')],
      observations: [],
      answerContains: ['评测供应商'],
      unverifiedReferences: 1,
    ),
    EvalCase(
      id: 'budget_failure_disclosed',
      question: '不存在的项目 $missing 成本是多少？',
      replies: [
        _call('project_budget', missingBudget, 1),
        _answer('预算查询失败，无法确定成本。'),
      ],
      observations: [
        ExpectedObservation('project_budget', missingBudget, {}, failed: true),
      ],
      answerContains: ['失败', '无法确定'],
    ),
    EvalCase(
      id: 'empty_results',
      question: '查询名为不存在的供应商的记录。',
      replies: [_call('query', empty, 1), _answer('未找到供应商。')],
      observations: [
        ExpectedObservation('query', empty, {'total': 0, 'rows': []}),
      ],
      answerContains: ['未找到'],
    ),
    EvalCase(
      id: 'write_tool_rejected',
      question: '删除供应商 $supplier。',
      replies: [_call('delete', write, 1), _answer('只读助手不支持删除，操作失败。')],
      observations: [ExpectedObservation('delete', write, {}, failed: true)],
      answerContains: ['只读', '失败'],
    ),
  ];
}

// Include all SQL tables, not just the objects visible through the ontology.
String _databaseContent(Store store) => jsonEncode({
  for (final table in store.db.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
  ))
    table['name'] as String:
        (store.db
            .select(
              'SELECT * FROM "${(table['name'] as String).replaceAll('"', '""')}"',
            )
            .map((row) => jsonEncode(row.values.toList()))
            .toList()
          ..sort()),
});

Future<Map<String, Object?>> runAssistantEvaluation() async {
  final directory = Directory.systemTemp.createTempSync('assistant_eval_');
  Store? store;
  final results = <Map<String, Object?>>[];
  try {
    store = Store.open(
      '${directory.path}/synthetic.db',
      device: 'eval',
      clock: () => DateTime.utc(2026, 9, 29),
    );
    for (final task in _cases(store)) {
      final before = _databaseContent(store);
      final model = fixtures.FakeModel([...task.replies]);
      try {
        final answer = await store.askWithEvidence(model.client, task.question);
        final observations = [
          for (final observation in answer.observations)
            <String, Object?>{
              'call_id': observation.callId,
              'tool': observation.tool,
              'arguments': jsonDecode(observation.arguments),
              'result': jsonDecode(observation.result),
              'round': observation.round,
              'failed': observation.failed,
            },
        ];
        final wire = (model.requests.last['messages'] as List)
            .where((message) => message['role'] == 'tool')
            .toList();
        final wireMatches =
            wire.length == answer.observations.length &&
            List.generate(
              wire.length,
              (i) =>
                  wire[i]['tool_call_id'] == answer.observations[i].callId &&
                  wire[i]['content'] == answer.observations[i].result,
            ).every((v) => v);
        results.add({
          ...gradeAssistantCase(
            task,
            text: answer.text,
            observations: observations,
            unverifiedReferences: answer.unverifiedReferences,
            readOnly: before == _databaseContent(store),
            wireMatchesEvidence: wireMatches,
          ),
          'model_calls': answer.modelCalls,
          'elapsed_ms': answer.elapsed.inMilliseconds,
          'warnings': answer.warnings,
        });
      } catch (error) {
        results.add({
          'id': task.id,
          'question': task.question,
          'pass': false,
          'error': '$error',
          'read_only': before == _databaseContent(store),
        });
      }
    }
  } finally {
    store?.close();
    directory.deleteSync(recursive: true);
  }
  return {
    'mode': 'scripted_contract',
    'replay_only': true,
    'live_model_evaluated': false,
    'scope':
        'Synthetic SQLite + scripted model replies through askWithEvidence; '
        'checks contracts and selected answer tokens, not real model accuracy '
        'or unrestricted natural-language correctness.',
    'pass':
        results.isNotEmpty && results.every((result) => result['pass'] == true),
    'passed': results.where((result) => result['pass'] == true).length,
    'total': results.length,
    'cases': results,
  };
}

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty) {
    stderr.writeln('Usage: dart run tool/assistant_eval.dart (offline only)');
    exitCode = 64;
    return;
  }
  final report = await runAssistantEvaluation();
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
  if (report['pass'] != true) exitCode = 1;
}
