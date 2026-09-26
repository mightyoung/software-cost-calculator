import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_ai'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('list becomes a reviewed proposal, then a project', () async {
    final s = device('A');
    final sup = s.save('supplier', supplier('甲泵业'));
    final pump = s.save('product', {
      ...product('离心水泵', unit: '台'),
      'model': 'IS65-50-160',
      'specification': '流量50m³/h 扬程32m',
    });
    final valve = s.save('product', product('闸阀'));
    final pro = s.save('project', project('OLD'));
    s.save('quotation', {
      ...quotation(sup, pump, pro, '3200.5'),
      'unit_snapshot': '台',
    });

    final model = FakeModel([
      jsonReply({
        'items': [
          {
            'name': '离心水泵',
            'requirements': '50m³/h，扬程32m',
            'qty': '2',
            'unit': '台',
            'keywords': ['水泵', 'IS65'],
          },
          {
            'name': '闸阀 DN100',
            'qty': '约4',
            'unit': '个',
            'keywords': ['闸阀'],
          },
          {
            'name': '控制柜',
            'qty': 1,
            'unit': '面',
            'keywords': ['控制柜'],
          },
        ],
      }),
      jsonReply({
        'matches': [
          {
            'index': 0,
            'product_id': pump,
            'confidence': 'high',
            'reason': '型号一致',
          },
          // An id that was never a candidate must be discarded.
          {'index': 1, 'product_id': newUuid(), 'confidence': 'high'},
        ],
      }),
    ]);
    const list = '序号 设备 参数 数量\n1 离心水泵 50m³/h 32m 2台\n2 闸阀DN100 约4个\n3 控制柜 1面';
    final lines = await s.proposeFromList(
      model.client,
      list,
      asOf: DateTime.utc(2026, 9, 10),
    );

    expect(lines.map((l) => l.productId), [pump, null, null]);
    expect(lines.map((l) => l.confidence), ['high', 'low', 'low']);
    expect(lines[0].quote!.price, '3200.5');
    expect(lines[1].candidates.single.id, valve);
    expect(lines[2].candidates, isEmpty);
    // Matching sends specs but never prices; only two model calls were made.
    expect(model.requests, hasLength(2));
    final matchPrompt = jsonEncode(model.requests[1]['messages']);
    expect(matchPrompt, contains('IS65-50-160'));
    expect(matchPrompt, isNot(contains('3200.5')));
    expect(model.requests[0]['response_format'], {'type': 'json_object'});

    final id = s.createProjectFromProposal(project('NEW'), lines);
    final b = s.budget(id, asOf: DateTime.utc(2026, 9, 10));
    expect(b.lines.map((l) => l.data['qty']), ['2', '4', '1']);
    expect(b.lines.map((l) => l.cost), ['6401', '0', '0']);
    expect(b.lines.map((l) => l.warnings), [
      <String>[],
      ['needs_inquiry'],
      ['needs_inquiry'],
    ]);
    expect(b.lines[1].data['notes'], contains('清单原文数量：约4'));
    expect(b.lines[2].data['name'], '控制柜');
  });

  test(
    'assistant answers through read-only tools and survives bad calls',
    () async {
      final s = device('A');
      s.save('product', {...product('离心水泵'), 'model': 'IS65-50-160'});
      Map<String, Object?> call(String id, String name, Object args) => {
        'id': id,
        'type': 'function',
        'function': {'name': name, 'arguments': jsonEncode(args)},
      };
      final model = FakeModel([
        {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            call('c1', 'search_products', {
              'keywords': ['水泵'],
            }),
            call('c2', 'drop_tables', {}),
            call('c3', 'project_budget', {'project_id': 'nope'}),
          ],
        },
        {'role': 'assistant', 'content': '库里有 1 种离心水泵，型号 IS65-50-160。'},
      ]);
      final answer = await s.ask(model.client, '有哪些水泵？');
      expect(answer, contains('IS65-50-160'));
      final toolMessages = (model.requests[1]['messages']! as List)
          .cast<Map>()
          .where((m) => m['role'] == 'tool')
          .map((m) => m['content'] as String)
          .toList();
      expect(toolMessages[0], contains('IS65-50-160'));
      expect(toolMessages[1], contains('未知工具'));
      expect(toolMessages[2], contains('error'));
      expect(model.requests[0]['tools'], hasLength(assistantTools.length));
    },
  );

  test('empty JSON replies are retried once, then reported', () async {
    final s = device('A');
    final model = FakeModel([
      {'role': 'assistant', 'content': ''},
      jsonReply({'items': []}),
    ]);
    expect(await s.proposeFromList(model.client, '空清单'), isEmpty);
    final failing = FakeModel([
      {'role': 'assistant', 'content': ''},
      {'role': 'assistant', 'content': '不是json'},
    ]);
    await expectLater(
      s.proposeFromList(failing.client, 'x'),
      throwsA(isA<LlmException>()),
    );
  });
}
