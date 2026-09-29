// Opt-in synthetic online smoke: DEEPSEEK_API_KEY in environment only.
import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';

Future<void> main(List<String> args) async {
  final key = Platform.environment['DEEPSEEK_API_KEY'];
  if (args.isNotEmpty || key == null || key.isEmpty) {
    stderr.writeln('Set DEEPSEEK_API_KEY; no command arguments accepted.');
    exitCode = 64;
    return;
  }
  final dir = Directory.systemTemp.createTempSync('compact_live_');
  final store = Store.open('${dir.path}/synthetic.db', device: 'compact-eval');
  final tools = <String>[];
  var compactEvents = 0;
  try {
    final before = store.db
        .select('SELECT COUNT(*) AS n FROM product')
        .single['n'];
    final answer = await store.askWithEvidence(
      LlmClient(LlmConfig(apiKey: key)),
      '请从此前问答回查“交付代号”，并说出最新的采购数量。只复述历史约定，不查本机物料库，不猜测。',
      history: [
        AssistantTurn(
          '初始采购数量为2台，历史回复中有交付说明。',
          '${'一般背景资料。' * 3000}\n交付代号：CMP741。',
        ),
        const AssistantTurn('最新修正：采购数量改为3台，其他约定不变。', '已记录，数量以最新修正为准。'),
      ],
      onTool: tools.add,
      onCompact: () => compactEvents++,
    );
    final after = store.db
        .select('SELECT COUNT(*) AS n FROM product')
        .single['n'];
    final checks = {
      'automatically_compacted':
          answer.contextCompactions > 0 && compactEvents > 0,
      'recalled_original': tools.contains('recall_context'),
      'delivery_code': answer.text.contains('CMP741'),
      'latest_quantity': RegExp(r'3\s*台').hasMatch(answer.text),
      'no_business_observations': answer.observations.isEmpty,
      'no_product_writes': before == after,
    };
    final passed = checks.values.every((v) => v);
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'provider': 'DeepSeek',
        'model': 'deepseek-flash',
        'synthetic_only': true,
        'checks': checks,
        'passed': passed,
        'tools': tools,
        'answer': answer.toJson(),
        'manual_review_required': true,
      }),
    );
    if (!passed) exitCode = 1;
  } catch (error) {
    stdout.writeln(
      jsonEncode({
        'passed': false,
        'error': '$error'.replaceAll(key, '[redacted]'),
      }),
    );
    exitCode = 1;
  } finally {
    store.close();
    dir.deleteSync(recursive: true);
  }
}
