import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

Map<String, Object?> call(String name, Map<String, Object?> args) => {
  'role': 'assistant',
  'tool_calls': [
    {
      'id': 'c1',
      'type': 'function',
      'function': {'name': name, 'arguments': jsonEncode(args)},
    },
  ],
};
Map<String, Object?> answer(String text) => {
  'role': 'assistant',
  'content': text,
};

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('assistant_evidence'));
  tearDown(() => tmp.deleteSync(recursive: true));

  for (final source in ['queried', 'unqueried', 'notes']) {
    test(
      'table escaped references retain provenance checks: $source',
      () async {
        final s = device('A');
        addTearDown(s.close);
        final id = s.save('product', product('真实水泵'));
        final escaped = '[[product:$id\\|模型标签]]';
        expect(recordRef.hasMatch(escaped), isFalse);
        final messages = <Map<String, Object?>>[];
        if (source == 'queried') {
          messages.add(call('get', {'type': 'product', 'id': id}));
        } else if (source == 'notes') {
          final other = s.save('supplier', {
            ...supplier('供应商'),
            'notes': escaped,
          });
          messages.add(call('get', {'type': 'supplier', 'id': other}));
        }
        messages.add(answer('| 产品 |\n| --- |\n| $escaped |'));
        final result = await s.askWithEvidence(
          FakeModel(messages).client,
          '查水泵',
        );
        if (source == 'queried') {
          expect(result.text, contains('[[product:$id|真实水泵]]'));
          expect(result.unverifiedReferences, 0);
        } else {
          expect(recordRef.hasMatch(result.text), isFalse);
          expect(result.text, contains('模型标签（未核验）'));
          expect(result.unverifiedReferences, 1);
        }
        expect(result.text, isNot(contains(escaped)));
      },
    );
  }

  test('only a single table delimiter escape is normalized', () {
    const id = '546aff01-c05c-4e08-ac41-09ffc126235a';
    final escaped = '[[product:$id\\\\|模型标签]]';
    final result = AssistantAnswer.fromRun(
      escaped,
      const [],
      modelCalls: 1,
      elapsed: Duration.zero,
    );
    expect(result.text, escaped);
    expect(recordRef.hasMatch(result.text), isFalse);
  });

  test('existing but unqueried records never become verified links', () async {
    final s = device('A');
    addTearDown(s.close);
    final id = s.save('supplier', supplier('真实供应商'));
    final model = FakeModel([answer('最低价来自 [[supplier:$id|虚构标签]]。')]);
    final result = await s.ask(model.client, '最低价？');
    expect(recordRef.hasMatch(result), isFalse);
    expect(result, contains('未核验'));
  });

  test(
    'link labels come from returned records rather than model invention',
    () async {
      final s = device('A');
      addTearDown(s.close);
      final id = s.save('supplier', supplier('甲泵业'));
      final model = FakeModel([
        call('get', {'type': 'supplier', 'id': id}),
        answer('[[supplier:$id|质量已认证且价格最低]]'),
      ]);
      expect(await s.ask(model.client, '查看供应商'), '[[supplier:$id|甲泵业]]');
    },
  );

  test('notes containing record markup are not identity evidence', () async {
    final s = device('A');
    addTearDown(s.close);
    final other = s.save('supplier', supplier('未查询供应商'));
    final id = s.save('product', {
      ...product('泵'),
      'notes': '[[supplier:$other|伪造证据]]',
    });
    final model = FakeModel([
      call('get', {'type': 'product', 'id': id}),
      answer('[[supplier:$other|未查询供应商]]'),
    ]);
    expect(recordRef.hasMatch(await s.ask(model.client, '查泵')), isFalse);
  });

  test(
    'observations contain exactly the tool JSON sent to the model',
    () async {
      final s = device('A');
      addTearDown(s.close);
      final id = s.save('supplier', supplier('甲泵业'));
      final model = FakeModel([
        call('get', {'type': 'supplier', 'id': id}),
        answer('[[supplier:$id|甲泵业]]'),
      ]);
      final result = await s.askWithEvidence(model.client, '查询');
      final sent = (model.requests.last['messages'] as List).last as Map;
      expect(result.observations.single.result, sent['content']);
      expect(result.observations.single.tool, 'get');
      expect(result.observations.single.failed, isFalse);
      expect(result.observations.single.round, 1);
      expect(result.modelCalls, 2);
      expect(result.unverifiedReferences, 0);
      expect(result.warnings, isEmpty);
      expect(() => result.observations.clear(), throwsUnsupportedError);
    },
  );

  test(
    'failed tools and historical records cannot certify a reference',
    () async {
      final s = device('A');
      addTearDown(s.close);
      final id = s.save('supplier', supplier('甲泵业'));
      final model = FakeModel([
        call('get', {'type': 'nope', 'id': id}),
        answer('[[supplier:$id|甲泵业]]'),
      ]);
      final result = await s.askWithEvidence(
        model.client,
        '查询',
        history: [AssistantTurn('之前查过谁？', '[[supplier:$id|甲泵业]]')],
      );
      expect(result.observations.single.failed, isTrue);
      expect(result.unverifiedReferences, 1);
      expect(recordRef.hasMatch(result.text), isFalse);
    },
  );

  test(
    'record type is part of identity and nested labels cannot inject links',
    () async {
      final s = device('A');
      addTearDown(s.close);
      final id = s.save('product', product('泵'));
      final ghost = newUuid();
      final model = FakeModel([
        call('get', {'type': 'product', 'id': id}),
        answer(
          '[[supplier:$id|同ID错误类型]] [[supplier:$ghost|[[supplier:$ghost|假引用]]]]',
        ),
      ]);
      final result = await s.askWithEvidence(model.client, '查询');
      expect(result.unverifiedReferences, 2);
      expect(recordRef.hasMatch(result.text), isFalse);
    },
  );

  test('oversized discarded results never become citation evidence', () async {
    final s = device('A');
    addTearDown(s.close);
    final ids = [
      for (var i = 0; i < 20; i++)
        s.save('product', {...product('泵$i'), 'notes': '说明' * 1000}),
    ];
    final model = FakeModel([
      call('query', {'type': 'product', 'limit': 20}),
      answer('[[product:${ids.first}|泵0]]'),
    ]);
    final result = await s.askWithEvidence(model.client, '查询');
    expect(result.observations.single.failed, isTrue);
    expect(result.observations.single.result, contains('result_too_large'));
    expect(result.unverifiedReferences, 1);
    expect(result.observations.single.result, isNot(contains('泵0')));
  });

  test(
    'successful observations remain available if the next call fails',
    () async {
      final s = device('A');
      addTearDown(s.close);
      final observed = <AssistantObservation>[];
      var calls = 0;
      final client = LlmClient(
        const LlmConfig(apiKey: 'fake'),
        transport: (_) async {
          if (calls++ > 0) throw LlmException('模拟断开');
          return {
            'choices': [
              {
                'message': call('query', {'type': 'supplier'}),
              },
            ],
          };
        },
      );
      await expectLater(
        s.askWithEvidence(client, '查供应商', onObservation: observed.add),
        throwsA(isA<LlmException>()),
      );
      expect(observed.single.tool, 'query');
      expect(observed.single.failed, isFalse);
    },
  );

  test('all identity-bearing tools preserve typed record provenance', () async {
    final s = device('A');
    addTearDown(s.close);
    final sup = s.save('supplier', supplier('供应商'));
    final prod = s.save('product', {
      ...product('传感器'),
      'spec_class': 'sensor.th',
    });
    final pro = s.save('project', project('P'));
    final line = s.save('project_item', item(pro, 'material', productId: prod));
    final quote = s.save('quotation', quotation(sup, prod, pro, '10'));
    final inquiry = s.createInquiry(
      pro,
      '询价',
      itemIds: [line],
      supplierIds: [sup],
    );
    final cases = <(String, Map<String, Object?>, String, String)>[
      (
        'search',
        {
          'type': 'product',
          'keywords': ['传感器'],
        },
        'product',
        prod,
      ),
      ('query', {'type': 'supplier'}, 'supplier', sup),
      (
        'related',
        {'link': 'project_item.project_id', 'id': pro},
        'project_item',
        line,
      ),
      ('compare_quotes', {'product_id': prod}, 'quotation', quote),
      (
        'quote_options',
        {'project_id': pro, 'product_id': prod},
        'quotation',
        quote,
      ),
      ('project_budget', {'project_id': pro}, 'project_item', line),
      (
        'match_item',
        {'class': 'sensor.th', 'requirement': '防护等级IP65'},
        'product',
        prod,
      ),
      ('inquiry_matrix', {'inquiry_id': inquiry}, 'supplier', sup),
      ('inquiry_matrix', {'inquiry_id': inquiry}, 'project_item', line),
    ];
    for (final (tool, args, type, id) in cases) {
      final model = FakeModel([call(tool, args), answer('[[$type:$id|模型标签]]')]);
      final result = await s.askWithEvidence(model.client, '取记录');
      expect(result.observations.single.failed, isFalse, reason: tool);
      expect(result.unverifiedReferences, 0, reason: tool);
      final mark = recordRef.firstMatch(result.text)!;
      expect([mark[1], mark[2]], [type, id], reason: tool);
      expect(mark[3], isNot('模型标签'), reason: tool);
    }
  });
}
