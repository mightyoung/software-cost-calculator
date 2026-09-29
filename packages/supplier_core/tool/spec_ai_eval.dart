// Scores rules + AI on the labelled sample requirement (design §12, phase 4:
// ≥ 90% of clauses right, nothing silently wrong). The key is read from the
// environment and never written anywhere. A local OpenAI-compatible model
// works too (any non-empty key):
//   DEEPSEEK_API_KEY=sk-... dart run tool/spec_ai_eval.dart [model]
//   SPEC_AI_BASE_URL=http://localhost:11434 DEEPSEEK_API_KEY=x \
//     dart run tool/spec_ai_eval.dart qwen2.5:14b
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';

import '../test/spec_sample.dart';

Future<void> main(List<String> args) async {
  final key = Platform.environment['DEEPSEEK_API_KEY'];
  if (key == null || key.isEmpty) {
    stderr.writeln('请先设置环境变量 DEEPSEEK_API_KEY');
    exitCode = 64;
    return;
  }
  final base = Platform.environment['SPEC_AI_BASE_URL'];
  final llm = LlmClient(
    LlmConfig(
      apiKey: key,
      baseUrl: base ?? 'https://api.deepseek.com',
      model: args.isEmpty ? 'deepseek-flash' : args.first,
    ),
  );
  var total = 0, rules = 0, right = 0, silent = 0, added = 0, dropped = 0;
  for (final (name, text, want) in sample) {
    final item = draftItem(name, text);
    var clauses = item.clauses;
    if (clauses.length != want.length) {
      throw StateError('$name 条款数与标注不一致：${clauses.length}/${want.length}');
    }
    bool ok(SpecClause c, int i) {
      final got = {
        for (final x in c.constraints) sampleKey(x.property, x.op, x.value),
      };
      final exp = {for (final (p, op, v) in want[i]) sampleKey(p, op, v)};
      return got.length == exp.length && got.containsAll(exp);
    }

    rules += [
      for (final (i, c) in clauses.indexed) ok(c, i),
    ].where((x) => x).length;
    if (item.specClass != null) {
      final r = await aiReadClauses(llm, item.specClass!, clauses);
      clauses = r.clauses;
      added += r.added;
      dropped += r.dropped;
    }
    if (clauses.length != want.length) {
      throw StateError('$name AI 返回条款数与标注不一致：${clauses.length}/${want.length}');
    }
    for (final (i, c) in clauses.indexed) {
      total++;
      if (ok(c, i)) {
        right++;
      } else {
        if (c.hint == null && c.constraints.isNotEmpty) silent++;
        stdout.writeln(
          '✗ $name「${c.text}」 ${[for (final k in c.constraints) k.describe()]}',
        );
      }
    }
  }
  stdout.writeln(
    '\n条款 $total：规则 $rules 条正确；规则 + AI $right 条正确'
    '（${(right * 100 / total).toStringAsFixed(1)}%），静默错误 $silent；'
    'AI 采纳 $added 个条件、丢弃 $dropped 个',
  );
  if (total == 0 || right * 10 < total * 9 || silent > 0) exitCode = 1;
}
