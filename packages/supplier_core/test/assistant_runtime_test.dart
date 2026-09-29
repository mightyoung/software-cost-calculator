import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

Map<String, Object?> toolCall(String id, String name, Object args) => {
  'id': id,
  'type': 'function',
  'function': {'name': name, 'arguments': jsonEncode(args)},
};

Map<String, Object?> toolReply(List<Object?> calls) => {
  'role': 'assistant',
  'content': null,
  'tool_calls': calls,
};

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('assistant_runtime'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'malformed tool calls become actionable errors, never cast crashes',
    () async {
      final s = device('A');
      addTearDown(s.close);
      for (final call in [
        null,
        'invalid',
        {'id': 'c1'},
        toolCall('', 'get', {}),
      ]) {
        final model = FakeModel([
          toolReply([call]),
        ]);
        await expectLater(
          s.ask(model.client, '查询'),
          throwsA(isA<LlmException>()),
        );
      }
    },
  );

  test('duplicate call ids are rejected before executing tools', () async {
    final s = device('A');
    addTearDown(s.close);
    final model = FakeModel([
      toolReply([
        toolCall('c1', 'describe', {}),
        toolCall('c1', 'describe', {}),
      ]),
    ]);
    final invoked = <String>[];
    await expectLater(
      s.ask(model.client, '查询', onTool: invoked.add),
      throwsA(isA<LlmException>()),
    );
    expect(invoked, isEmpty);
  });

  test('tool bursts have a budget independent of model rounds', () async {
    final s = device('A');
    addTearDown(s.close);
    final model = FakeModel([
      toolReply([
        for (var i = 0; i < 100; i++) toolCall('c$i', 'describe', {}),
      ]),
    ]);
    final invoked = <String>[];
    await expectLater(
      s.ask(model.client, '查询', onTool: invoked.add),
      throwsA(isA<LlmException>()),
    );
    expect(invoked, isEmpty);
  });

  test('empty final response is not a successful answer', () async {
    final s = device('A');
    addTearDown(s.close);
    final model = FakeModel([
      {'role': 'assistant', 'content': '  '},
    ]);
    await expectLater(s.ask(model.client, '查询'), throwsA(isA<LlmException>()));
  });

  test(
    'oversized observations are reported rather than sent unbounded',
    () async {
      final s = device('A');
      addTearDown(s.close);
      for (var i = 0; i < 20; i++) {
        s.save('product', {...product('泵$i'), 'notes': '说明' * 1000});
      }
      final model = FakeModel([
        toolReply([
          toolCall('c1', 'query', {'type': 'product'}),
        ]),
        {'role': 'assistant', 'content': '记录太大，需要缩小查询范围。'},
      ]);
      await s.ask(model.client, '查泵');
      final messages = model.requests[1]['messages'] as List;
      final observation = (messages.last as Map)['content'] as String;
      expect(observation.length, lessThan(20000));
      expect(jsonDecode(observation), containsPair('error', isNotNull));
    },
  );

  test('malformed and truncated provider replies are domain errors', () async {
    for (final choice in [
      null,
      'invalid',
      {
        'message': {'role': 'assistant', 'content': 12},
      },
      {
        'finish_reason': 'length',
        'message': {'role': 'assistant', 'content': '{"items":[]}'},
      },
    ]) {
      final llm = LlmClient(
        const LlmConfig(apiKey: 'fake'),
        transport: (_) async => {
          'choices': [choice],
        },
      );
      await expectLater(llm.complete([]), throwsA(isA<LlmException>()));
    }
  });

  test(
    'follow-up replays bounded complete turns, with fresh data instructions',
    () async {
      final s = device('A');
      addTearDown(s.close);
      final model = FakeModel([
        {'role': 'assistant', 'content': '需要重新查价。'},
      ]);
      await s.ask(
        model.client,
        '这个供应商呢？',
        history: [for (var i = 0; i < 10; i++) AssistantTurn('问题$i', '回答$i')],
      );
      final messages = model.requests.single['messages'] as List;
      expect(messages.length, 22); // system + all ten small pairs + question
      expect((messages[1] as Map)['content'], '问题0');
      expect((messages[messages.length - 2] as Map)['content'], '回答9');
      expect((messages.first as Map)['content'], contains('重新查询'));
      expect((messages.last as Map)['content'], '这个供应商呢？');
    },
  );

  test(
    'history character budget archives old pairs with recall pointers',
    () async {
      final s = device('A');
      addTearDown(s.close);
      final model = FakeModel([
        {'role': 'assistant', 'content': '好'},
      ]);
      await s.ask(
        model.client,
        '追问',
        history: [
          AssistantTurn('旧问题', '旧' * maxAssistantHistoryChars),
          const AssistantTurn('新问题', '新回答'),
        ],
      );
      final messages = model.requests.single['messages'] as List;
      expect(messages, hasLength(5));
      expect((messages[1] as Map)['content'], contains('recall_context'));
      expect((messages[1] as Map)['content'], contains('旧问题'));
      expect((messages[2] as Map)['content'], '新问题');
    },
  );

  test(
    'cancellation releases waiting and prevents late tool execution',
    () async {
      final s = device('A');
      addTearDown(s.close);
      final response = Completer<Map<String, Object?>>();
      final entered = Completer<void>();
      final llm = LlmClient(
        const LlmConfig(apiKey: 'fake'),
        transport: (_) {
          entered.complete();
          return response.future;
        },
      );
      final token = AssistantCancellation();
      final invoked = <String>[];
      final result = s.ask(llm, '查询', cancellation: token, onTool: invoked.add);
      final check = expectLater(result, throwsA(isA<LlmException>()));
      await entered.future;
      token.cancel();
      await check;
      response.complete({
        'choices': [
          {
            'message': toolReply([toolCall('c1', 'describe', {})]),
          },
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(invoked, isEmpty);
    },
  );

  test(
    'archive recall neither certifies history nor spends business rounds',
    () async {
      final s = device('A');
      addTearDown(s.close);
      final id = s.save('supplier', supplier('历史供应商'));
      final model = FakeModel([
        toolReply([
          toolCall('recall1', 'recall_context', {'query': '历史供应商'}),
        ]),
        for (var i = 0; i < maxToolRounds; i++)
          toolReply([
            toolCall('q$i', 'query', {'type': 'product'}),
          ]),
        {'role': 'assistant', 'content': '旧引用[[supplier:$id|历史供应商]]需要重新查询'},
      ]);
      final answer = await s.askWithEvidence(
        model.client,
        '继续',
        history: [
          AssistantTurn('以前的资料', '${'长文本' * 6000}[[supplier:$id|历史供应商]]'),
        ],
      );
      expect(answer.contextCompactions, greaterThan(0));
      expect(answer.observations, hasLength(maxToolRounds));
      expect(answer.unverifiedReferences, 1);
      expect(model.requests, hasLength(maxToolRounds + 2));
      final recalled = (model.requests[1]['messages'] as List)
          .where((m) => m['role'] == 'tool')
          .first;
      expect(recalled['content'], contains('match_offset'));
      expect(recalled['content'], contains('历史供应商'));
      final finalTools = model.requests.last['tools'] as List;
      expect(finalTools, hasLength(1));
      expect(finalTools.single['function']['name'], 'recall_context');
    },
  );

  test('deadline stops waiting for the provider', () async {
    final s = device('A');
    addTearDown(s.close);
    final response = Completer<Map<String, Object?>>();
    final llm = LlmClient(
      const LlmConfig(apiKey: 'fake'),
      transport: (_) => response.future,
    );
    await expectLater(
      s.ask(llm, '查询', timeout: const Duration(milliseconds: 10)),
      throwsA(
        isA<LlmException>().having((e) => e.message, 'message', contains('超时')),
      ),
    );
    response.complete({
      'choices': [
        {
          'message': {'role': 'assistant', 'content': '晚到的回答'},
        },
      ],
    });
  });

  test(
    'last round synthesizes known results without offering more tools',
    () async {
      final s = device('A');
      addTearDown(s.close);
      final model = FakeModel([
        for (var i = 0; i < maxToolRounds; i++)
          toolReply([
            toolCall('c$i', 'query', {'type': 'supplier'}),
          ]),
        {'role': 'assistant', 'content': '未找到供应商。'},
      ]);
      expect(await s.ask(model.client, '查供应商'), '未找到供应商。');
      expect(model.requests, hasLength(maxToolRounds + 1));
      expect(model.requests.last.containsKey('tools'), isFalse);
      expect(
        (model.requests.last['messages'] as List).last['content'],
        contains('尚未查清'),
      );
    },
  );

  test('overlong questions never call the model', () async {
    final s = device('A');
    addTearDown(s.close);
    final model = FakeModel([]);
    await expectLater(
      s.ask(model.client, '问' * (maxAssistantQuestionChars + 1)),
      throwsA(isA<LlmException>()),
    );
    expect(model.requests, isEmpty);
  });

  test(
    'combined observations cannot exceed the request context budget',
    () async {
      final s = device('A');
      addTearDown(s.close);
      for (var i = 0; i < 5; i++) {
        s.save('product', {...product('泵$i'), 'notes': '说明' * 1000});
      }
      final model = FakeModel([
        for (var i = 0; i < maxToolRounds; i++)
          toolReply([
            toolCall('c$i', 'query', {'type': 'product', 'limit': 5}),
          ]),
        {'role': 'assistant', 'content': '不能无界积累上下文'},
      ]);
      var notifications = 0;
      final answer = await s.askWithEvidence(
        model.client,
        '查产品',
        onCompact: () => notifications++,
      );
      expect(answer.text, '不能无界积累上下文');
      expect(answer.contextCompactions, greaterThan(0));
      expect(notifications, answer.contextCompactions);
      expect(answer.observations, hasLength(maxToolRounds));
      expect(answer.observations.first.result, contains('说明'));
      expect(model.requests, hasLength(maxToolRounds + 1));
      for (final request in model.requests) {
        expect(jsonEncode(request).length, lessThanOrEqualTo(100000));
        expect(
          jsonEncode(request['messages']).length,
          lessThanOrEqualTo(maxAssistantContextChars),
        );
      }
    },
  );

  test(
    'large budgets remain answerable with fewer details and full totals',
    () async {
      final s = device('A');
      addTearDown(s.close);
      final pro = s.save('project', project('大项目'));
      for (var i = 0; i < 50; i++) {
        s.save('project_item', {
          ...item(pro, 'other'),
          'name': '${'设' * 197}${i.toString().padLeft(3, '0')}',
          'qty': '1',
          'unit_cost': '1',
        });
      }
      final model = FakeModel([
        toolReply([
          toolCall('c1', 'project_budget', {'project_id': pro, 'limit': 1}),
        ]),
        {'role': 'assistant', 'content': '全项目成本 50，明细仅展示 1 行。'},
      ]);
      expect(await s.ask(model.client, '项目总成本？'), contains('50'));
      final messages = model.requests[1]['messages'] as List;
      final result =
          jsonDecode((messages.last as Map)['content'] as String) as Map;
      expect(result['error'], isNull);
      expect(result['cost'], '50');
      expect(result['total'], 50);
      expect(result['truncated'], isTrue);
      expect(result['lines'], hasLength(1));
    },
  );

  test(
    'large fresh final batches reach synthesis before being compacted',
    () async {
      final s = device('A');
      addTearDown(s.close);
      for (var i = 0; i < 5; i++) {
        s.save('product', {...product('最终物料$i'), 'notes': '说明' * 1000});
      }
      final model = FakeModel([
        for (var i = 0; i < maxToolRounds - 1; i++)
          toolReply([
            toolCall('q$i', 'query', {'type': 'supplier'}),
          ]),
        toolReply([
          for (var i = 0; i < 4; i++)
            toolCall('final$i', 'query', {'type': 'product', 'limit': 5}),
        ]),
        {'role': 'assistant', 'content': '已读取最终查询结果'},
      ]);
      final answer = await s.askWithEvidence(model.client, '查产品');
      final last = model.requests.last['messages'] as List;
      for (var i = 0; i < 4; i++) {
        final result = last.singleWhere((m) => m['tool_call_id'] == 'final$i');
        expect(result['content'], contains('最终物料4'));
        expect(result['content'], contains('说明'));
      }
      expect(answer.observations.every((o) => o.providedToModel), isTrue);
    },
  );

  test(
    'previously seen results remain recoverable when compacted at synthesis',
    () async {
      final s = device('A');
      addTearDown(s.close);
      for (var i = 0; i < 5; i++) {
        s.save('product', {...product('早期物料$i'), 'notes': '早期依据' * 500});
      }
      final model = FakeModel([
        for (var i = 0; i < maxToolRounds; i++)
          toolReply([
            toolCall('q$i', 'query', {'type': 'product', 'limit': 5}),
          ]),
        toolReply([
          toolCall('old', 'recall_context', {'id': 'c1', 'limit': 4000}),
        ]),
        {'role': 'assistant', 'content': '回查了早期对比依据'},
      ]);
      final answer = await s.askWithEvidence(model.client, '对比早期和最后结果');
      final tools = model.requests[maxToolRounds]['tools'] as List;
      expect(tools.single['function']['name'], 'recall_context');
      final original = (model.requests[1]['messages'] as List).singleWhere(
        (m) => m['tool_call_id'] == 'q0',
      );
      expect(original['content'], contains('早期依据'));
      final finalMessages = model.requests.last['messages'] as List;
      expect(finalMessages.where((m) => m['tool_call_id'] == 'q0'), isEmpty);
      expect(
        finalMessages.singleWhere((m) => m['tool_call_id'] == 'old')['content'],
        contains('早期依据'),
      );
      expect(answer.observations.every((o) => o.providedToModel), isTrue);
    },
  );

  test(
    'oversized final batch offers recovery and cannot certify unread records',
    () async {
      final s = device('A');
      addTearDown(s.close);
      String? id;
      for (var i = 0; i < 5; i++) {
        id = s.save('product', {...product('大批物料$i'), 'notes': '说明' * 1000});
      }
      final model = FakeModel([
        for (var i = 0; i < maxToolRounds - 1; i++)
          toolReply([
            toolCall('q$i', 'query', {'type': 'supplier'}),
          ]),
        toolReply([
          for (var i = 0; i < 8; i++)
            toolCall('final$i', 'query', {'type': 'product', 'limit': 5}),
        ]),
        toolReply([
          toolCall('read1', 'recall_context', {'id': 'c8', 'limit': 4000}),
        ]),
        {'role': 'assistant', 'content': '只读取部分，[[product:$id|大批物料4]]尚待核对'},
      ]);
      final answer = await s.askWithEvidence(model.client, '查产品');
      final recoveryTools = model.requests[maxToolRounds]['tools'] as List;
      expect(recoveryTools, hasLength(1));
      expect(recoveryTools.single['function']['name'], 'recall_context');
      final page = (model.requests[maxToolRounds + 1]['messages'] as List)
          .singleWhere((m) => m['tool_call_id'] == 'read1');
      expect(page['content'], contains('说明'));
      expect(
        answer.observations.where((o) => !o.providedToModel),
        hasLength(8),
      );
      expect(answer.unverifiedReferences, 1);
      expect(answer.warnings.join(), contains('尚未完整送达模型'));
    },
  );
}
