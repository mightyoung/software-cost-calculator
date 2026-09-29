import 'dart:convert';

import 'package:supplier_core/src/assistant_context.dart';
import 'package:test/test.dart';

void main() {
  test('large history is indexed and the exact original can be paged back', () {
    final original = '约束：必须含税且不少于2台。' + '资料🙂' * 6000;
    final context = AssistantContext(
      system: 'system rules',
      question: '继续这个要求',
      history: [
        [
          {'role': 'user', 'content': original},
          {'role': 'assistant', 'content': '待核对'},
        ],
        [
          {'role': 'user', 'content': '最新修正为3台'},
          {'role': 'assistant', 'content': '明白'},
        ],
      ],
    );
    final messages = context.messages();
    expect(messages.first['content'], 'system rules');
    expect(messages.last['content'], '继续这个要求');
    expect(jsonEncode(messages), contains('最新修正为3台'));
    expect(context.compactions, 1);
    final index = jsonDecode(context.recall('{}')) as Map;
    final id = (index['entries'] as List).first['id'];
    var offset = 0;
    final restored = StringBuffer();
    while (true) {
      final page =
          jsonDecode(context.recall(jsonEncode({'id': id, 'offset': offset})))
              as Map;
      restored.write(page['text']);
      if (page['next_offset'] == null) break;
      offset = page['next_offset'] as int;
    }
    final turns = jsonDecode(restored.toString()) as List;
    expect(turns.first['content'], original);
    expect(context.recall('{"query":"不少于2台"}'), contains(id));
    expect(context.recall('{"id":"missing"}'), contains('error'));
    expect(context.recall('{"offset":-1}'), contains('error'));
    expect(context.recall('{broken'), contains('error'));
  });

  test(
    'automatic compaction keeps whole tool batches and stable source copies',
    () {
      final context = AssistantContext(system: 'rules', question: '查所有物料');
      final raw = List.generate(12000, (_) => '值').join();
      for (var i = 0; i < 8; i++) {
        context.addBatch([
          {
            'role': 'assistant',
            'tool_calls': [
              {
                'id': 'call$i',
                'type': 'function',
                'function': {'name': 'query', 'arguments': '{}'},
              },
            ],
          },
          {'role': 'tool', 'tool_call_id': 'call$i', 'content': raw},
        ]);
        final messages = context.messages();
        expect(jsonEncode(messages).length, lessThanOrEqualTo(64000));
        final calls = <String>{};
        final results = <String>{};
        for (final message in messages) {
          if (message['tool_calls'] case final List values) {
            calls.addAll(values.map((v) => v['id'] as String));
          }
          if (message['role'] == 'tool')
            results.add(message['tool_call_id'] as String);
        }
        expect(calls, results);
        expect(calls, contains('call$i'));
      }
      expect(context.compactions, greaterThan(0));
      expect(context.recall('{"id":"c1"}'), contains('call0'));
    },
  );

  test(
    'small histories are not cut at six turns and never invoke compaction',
    () {
      final history = [
        for (var i = 0; i < 10; i++)
          [
            {'role': 'user', 'content': '问题$i'},
            {'role': 'assistant', 'content': '回答$i'},
          ],
      ];
      final context = AssistantContext(
        system: 's',
        question: 'q',
        history: history,
      );
      expect(context.messages(), hasLength(22));
      expect(context.compactions, 0);
      history.first.first['content'] = '后来被调用方修改';
      expect(jsonEncode(context.messages()), contains('问题0'));
    },
  );

  test(
    'only complete delivered archive pages certify a formerly unseen result',
    () {
      final context = AssistantContext(system: 's', question: 'q');
      final result = jsonEncode({
        'rows': [
          {'name': '泵', 'notes': '字🙂' * 24000},
        ],
      });
      context.addBatch([
        {
          'role': 'assistant',
          'tool_calls': [
            {
              'id': 'large',
              'type': 'function',
              'function': {'name': 'query', 'arguments': '{}'},
            },
          ],
        },
        {'role': 'tool', 'tool_call_id': 'large', 'content': result},
      ]);
      context.messages();
      context.markSent();
      expect(context.wasSupplied('large', 'query', '{}', result), isFalse);
      expect(context.hasUnreadToolResults, isTrue);
      var offset = 0;
      while (true) {
        final args = jsonEncode({'id': 'c1', 'offset': offset, 'limit': 4000});
        final pageText = context.recall(args);
        final page = jsonDecode(pageText) as Map;
        context.addBatch([
          {
            'role': 'assistant',
            'tool_calls': [
              {
                'id': 'read$offset',
                'type': 'function',
                'function': {'name': 'recall_context', 'arguments': args},
              },
            ],
          },
          {'role': 'tool', 'tool_call_id': 'read$offset', 'content': pageText},
        ]);
        context.messages();
        // Merely constructing a page is not evidence that the model saw it.
        expect(context.wasSupplied('large', 'query', '{}', result), isFalse);
        context.markSent();
        if (page['next_offset'] == null) break;
        offset = page['next_offset'] as int;
      }
      expect(context.wasSupplied('large', 'query', '{}', result), isTrue);
      expect(context.hasUnreadToolResults, isFalse);
      expect(
        context.wasSupplied('large', 'query', '{"other":true}', result),
        isFalse,
      );
    },
  );
}
