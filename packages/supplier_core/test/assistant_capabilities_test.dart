import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

Map<String, Object?> _call(String name, Map<String, Object?> args) => {
  'role': 'assistant',
  'tool_calls': [
    {
      'id': 'call1',
      'type': 'function',
      'function': {'name': name, 'arguments': jsonEncode(args)},
    },
  ],
};

LlmClient _model(
  List<Map<String, Object?>> responses, [
  List<Map<String, Object?>>? requests,
]) {
  var count = 0;
  return LlmClient(
    const LlmConfig(apiKey: 'fake'),
    transport: (body) async {
      requests?.add(body);
      return {
        'choices': [
          {'message': responses[count++]},
        ],
      };
    },
  );
}

class _Toolset implements AssistantToolset {
  _Toolset(this.name, this.run);
  final String name;
  final Future<String> Function(AiCancellation) run;
  @override
  List<Map<String, Object?>> get tools => [
    {
      'type': 'function',
      'function': {
        'name': name,
        'description': 'test',
        'parameters': {'type': 'object', 'properties': <String, Object?>{}},
      },
    },
  ];
  @override
  Future<String> execute(
    String name,
    Map<String, Object?> arguments, {
    required String callId,
    required AiCancellation cancellation,
  }) => run(cancellation);
}

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('capabilities'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'resume reuses model checkpoints following a committed action',
    () async {
      final store = device('a');
      addTearDown(store.close);
      final id = store.save('supplier', supplier('甲'));
      final jobs = AiJobStore.open('${tmp.path}/jobs.db');
      addTearDown(jobs.close);
      final job = jobs.create(AiTask.conversation, {'question': '修改甲'});
      var approvals = 0, providerCalls = 0;
      AssistantAppTools actions() => AssistantAppTools(
        store,
        permission: AssistantPermission.confirmWrites,
        sessionId: job.id,
        approve: (_) async {
          approvals++;
          return true;
        },
      );
      final first = jobs.start(job.id);
      final failing = LlmClient(
        const LlmConfig(apiKey: 'fake'),
        transport: (_) async {
          providerCalls++;
          if (providerCalls == 1)
            return {
              'choices': [
                {
                  'message': _call('update_record', {
                    'type': 'supplier',
                    'id': id,
                    'values': {'name': '乙'},
                  }),
                },
              ],
            };
          if (providerCalls == 2)
            return {
              'choices': [
                {
                  'message': _call('get', {'type': 'supplier', 'id': id}),
                },
              ],
            };
          throw LlmException('断线');
        },
      ).withCheckpoint(first);
      await expectLater(
        store.ask(failing, '修改甲', toolsets: [actions()]),
        throwsA(isA<LlmException>()),
      );
      first.pause('稍后继续');
      expect(approvals, 1);
      expect(providerCalls, 3);
      final second = jobs.start(job.id);
      var resumedCalls = 0;
      final resumed = LlmClient(
        const LlmConfig(apiKey: 'fake'),
        transport: (_) async {
          resumedCalls++;
          return {
            'choices': [
              {
                'message': {'content': '已经修改为乙。'},
              },
            ],
          };
        },
      ).withCheckpoint(second);
      await store.ask(resumed, '修改甲', toolsets: [actions()]);
      second.ready();
      expect(approvals, 1);
      expect(resumedCalls, 1);
      expect(store.get('supplier', id)!.version, 2);
    },
  );

  test(
    'optional async tools feed bounded evidence into the existing loop',
    () async {
      final store = device('a');
      addTearDown(store.close);
      final requests = <Map<String, Object?>>[];
      final answer = await store.askWithEvidence(
        _model([
          _call('public_lookup', {}),
          {'content': '查到了。'},
        ], requests),
        '查询公开资料',
        toolsets: [_Toolset('public_lookup', (_) async => '{"value":42}')],
      );
      expect(answer.observations.single.tool, 'public_lookup');
      expect(answer.observations.single.providedToModel, isTrue);
      expect(
        (requests.last['messages'] as List).last['content'],
        '{"value":42}',
      );
    },
  );

  test('absent capabilities cannot execute a hallucinated tool', () async {
    final store = device('a');
    addTearDown(store.close);
    final requests = <Map<String, Object?>>[];
    final answer = await store.askWithEvidence(
      _model([
        _call('web_fetch', {'url': 'https://example.com'}),
        {'content': '没有联网权限。'},
      ], requests),
      '打开网页',
    );
    expect(answer.observations.single.failed, isTrue);
    final names = (requests.first['tools'] as List).map(
      (t) => t['function']['name'],
    );
    expect(names, isNot(contains('web_fetch')));
  });

  test('extensions cannot replace authoritative domain tools', () async {
    final store = device('a');
    addTearDown(store.close);
    final requests = <Map<String, Object?>>[];
    await expectLater(
      store.ask(
        _model([], requests),
        '查询',
        toolsets: [_Toolset('get', (_) async => '{}')],
      ),
      throwsA(isA<LlmException>()),
    );
    expect(requests, isEmpty);
  });

  test(
    'cancellation wakes an awaited extension and prevents its late side effect',
    () async {
      final store = device('a');
      addTearDown(store.close);
      final cancellation = AssistantCancellation();
      final started = Completer<void>(), resume = Completer<void>();
      var changed = false;
      final pending = store.ask(
        _model([_call('pending_action', {})]),
        '操作',
        cancellation: cancellation,
        toolsets: [
          _Toolset('pending_action', (cancel) async {
            started.complete();
            await resume.future;
            cancel.check();
            changed = true;
            return '{}';
          }),
        ],
      );
      final rejected = expectLater(pending, throwsA(isA<LlmException>()));
      await started.future;
      cancellation.cancel();
      await rejected;
      resume.complete();
      await Future<void>.delayed(Duration.zero);
      expect(changed, isFalse);
    },
  );

  test('source links require successful supplied web source positions', () {
    AssistantObservation observation(
      String tool,
      String result, {
      bool supplied = true,
    }) => AssistantObservation(
      callId: 'c',
      tool: tool,
      arguments: '{}',
      result: result,
      round: 1,
      providedToModel: supplied,
    );
    final source = {
      'url': 'https://example.com',
      'title': '出处',
      'fetched_at': '2026-10-01T00:00:00Z',
    };
    final packet = jsonEncode({
      'sources': [
        source,
        {...source, 'url': 'file:///etc/passwd'},
      ],
    });
    final answer = AssistantAnswer.fromRun(
      '回答',
      [
        observation('get', packet),
        observation('web_fetch', packet, supplied: false),
        observation(
          'web_search',
          jsonEncode({
            'error': 'failed',
            'sources': [source],
          }),
        ),
        observation('web_extract', packet),
      ],
      modelCalls: 1,
      elapsed: Duration.zero,
    );
    expect(answer.sources, hasLength(1));
    expect(answer.sources.single.url, 'https://example.com');
  });

  test(
    'approved writes supply verifiable record links and durable replay',
    () async {
      final store = device('a');
      addTearDown(store.close);
      var approvals = 0;
      final actions = AssistantAppTools(
        store,
        permission: AssistantPermission.confirmWrites,
        sessionId: 'trusted',
        approve: (_) async {
          approvals++;
          return true;
        },
      );
      final arguments = {
        'type': 'supplier',
        'values': {'name': '甲'},
      };
      final requests = <Map<String, Object?>>[];
      final client = LlmClient(
        const LlmConfig(apiKey: 'fake'),
        transport: (body) async {
          requests.add(body);
          final calls = requests.length;
          if (calls < 3)
            return {
              'choices': [
                {'message': _call('create_record', arguments)},
              ],
            };
          final result =
              jsonDecode((body['messages'] as List).last['content'] as String)
                  as Map;
          return {
            'choices': [
              {
                'message': {'content': '[[supplier:${result['id']}|甲]]'},
              },
            ],
          };
        },
      );
      final answer = await store.askWithEvidence(
        client,
        '新增甲',
        toolsets: [actions],
      );
      expect(approvals, 1);
      expect(answer.unverifiedReferences, 0);
      final first = jsonDecode(answer.observations.first.result) as Map;
      expect(store.get('supplier', first['id'] as String)!.version, 1);
      expect(answer.observations.last.result, answer.observations.first.result);
    },
  );
}
