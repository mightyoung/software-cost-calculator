// Explicit, bounded online smoke for every LLM business path; synthetic data only.
// DEEPSEEK_API_KEY=... dart run tool/ai_workflow_live_eval.dart
import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import '../test/fixtures.dart' as fixtures;

Future<void> main(List<String> args) async {
  final key = Platform.environment['DEEPSEEK_API_KEY'];
  if (args.isNotEmpty || key == null || key.isEmpty) {
    stderr.writeln('Set DEEPSEEK_API_KEY; no command arguments are accepted.');
    exitCode = 64;
    return;
  }
  final dir = Directory.systemTemp.createTempSync('ai_workflows_');
  final store = Store.open('${dir.path}/synthetic.db', device: 'workflow-eval');
  final results = <Map<String, Object?>>[];
  try {
    final productId = store.save('product', {
      ...fixtures.product('离心水泵', unit: '台'),
      'model': 'ZX729',
      'specification': '流量10m³/h，扬程20m',
    });
    final before = jsonEncode(fixtures.content(store));
    for (final task in AiTask.values) {
      stderr.writeln('Running ${task.name}');
      final events = <Map<String, Object?>>[];
      final run = AiRun(
        task,
        onCall: (e) => events.add({
          'task': e.task.name,
          'call': e.call,
          'elapsed_ms': e.elapsed.inMilliseconds,
          'received_response': e.receivedResponse,
        }),
      );
      final llm = LlmClient(LlmConfig(apiKey: key), run: run);
      try {
        late Object output;
        late bool expected;
        switch (task) {
          case AiTask.offerExtraction:
            const source =
                '在线甲供应商，离心水泵ZX729，2台，单价1234.56元，含税13%，报价日期2026-09-29。';
            final offers = await store.extractOffers(llm, source);
            expected =
                offers.length == 1 &&
                offers.single['price'] == '1234.56' &&
                offers.single['qty'] == '2' &&
                offers.single['supplier'] == '在线甲供应商' &&
                offers.single['tax_mode'] == 'included';
            output = {
              'source': source,
              'offers': offers,
              'unverified_fields': [
                for (final o in offers)
                  store.planOffer(o, source: source).unverified.toList(),
              ],
            };
          case AiTask.listProposal:
            const source = '1. 离心水泵，型号ZX729，流量10m³/h，扬程20m，2台\n2. 变频控制柜，1面';
            final lines = await store.proposeFromList(llm, source);
            expected =
                lines.length == 2 &&
                lines[0].productId == productId &&
                lines[0].item.qty == '2' &&
                lines[1].productId == null;
            output = {
              'source': source,
              'lines': [
                for (final l in lines)
                  {
                    'name': l.item.name,
                    'qty': l.item.qty,
                    'product_id': l.productId,
                    'confidence': l.confidence,
                    'reason': l.reason,
                  },
              ],
            };
          case AiTask.clauseReading:
            final reading = await aiReadClauses(llm, 'computer.ipc', [
              const SpecClause(1, '显存不小于2GB', hint: '待核对'),
            ]);
            expected = reading.clauses.single.constraints.any(
              (c) =>
                  c.property == 'gpu.mem' &&
                  c.op == 'ge' &&
                  c.value['v'] == '2',
            );
            output = {
              'clauses': [for (final c in reading.clauses) c.toJson()],
              'added': reading.added,
              'dropped': reading.dropped,
            };
          case AiTask.parameterExtraction:
            final guesses = await aiExtractParams(
              llm,
              'computer.ipc',
              '显存不小于2GB',
            );
            expected = guesses.any(
              (g) =>
                  g.property == 'gpu.mem' &&
                  g.value['v'] == '2' &&
                  g.source == 'ai',
            );
            output = [
              for (final g in guesses)
                {
                  'property': g.property,
                  'value': g.value,
                  'evidence': g.evidence,
                  'source': g.source,
                },
            ];
          case AiTask.conversation:
            final answer = await store.askWithEvidence(
              llm,
              '本机有几条物料记录？请先查询，再用阿拉伯数字说明条数，不是库存数量。',
            );
            final text = answer.text
                .replaceAll(recordRef, '')
                .replaceAll(
                  RegExp(r'[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}'),
                  '',
                );
            expected =
                answer.observations.isNotEmpty &&
                answer.unverifiedReferences == 0 &&
                RegExp(r'(?<![0-9])1(?![0-9])').hasMatch(text);
            output = answer.toJson();
        }
        final readOnly = before == jsonEncode(fixtures.content(store));
        results.add({
          'task': task.name,
          'pass': expected && readOnly,
          'expected_fields': expected,
          'read_only': readOnly,
          'events': events,
          'output': output,
        });
      } catch (e) {
        results.add({
          'task': task.name,
          'pass': false,
          'error': '$e'.replaceAll(key, '[REDACTED]'),
          'events': events,
        });
      }
    }
  } finally {
    store.close();
    dir.deleteSync(recursive: true);
  }
  final pass = results.every((r) => r['pass'] == true);
  stdout.writeln(
    const JsonEncoder.withIndent('  ')
        .convert({
          'mode': 'live_model',
          'model': 'deepseek-flash',
          'synthetic_data_only': true,
          'manual_review_required': true,
          'scope':
              'Small workflow smoke, not accuracy or productivity certification.',
          'pass': pass,
          'passed': results.where((r) => r['pass'] == true).length,
          'total': results.length,
          'cases': results,
        })
        .replaceAll(key, '[REDACTED]'),
  );
  if (!pass) exitCode = 1;
}
