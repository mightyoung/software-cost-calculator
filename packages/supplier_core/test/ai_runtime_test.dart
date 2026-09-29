import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

Map<String, Object?> response(Object value) => {
  'choices': [
    {
      'message': {'content': jsonEncode(value)},
    },
  ],
};

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('ai_runtime'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('metadata observer failure cannot fail a valid response', () async {
    final run = AiRun(
      AiTask.clauseReading,
      onCall: (_) => throw StateError('observer'),
    );
    final client = LlmClient(
      const LlmConfig(apiKey: 'test'),
      run: run,
      transport: (_) async => response({'clauses': []}),
    );
    expect(await client.json('sys', 'input'), {'clauses': []});
    expect(
      () =>
          client.forTask(AiTask.clauseReading, cancellation: AiCancellation()),
      throwsA(isA<LlmException>()),
    );
    expect(
      client.forTask(AiTask.clauseReading, cancellation: run.cancellation),
      same(client),
    );
  });

  test('JSON retries consume the shared run budget', () async {
    final s = device('A');
    addTearDown(s.close);
    final events = <AiCallEvent>[];
    final run = AiRun(
      AiTask.offerExtraction,
      limits: const AiLimits(maxCalls: 1),
      onCall: events.add,
    );
    final llm = LlmClient(
      const LlmConfig(apiKey: 'test'),
      run: run,
      transport: (_) async => response({'offers': 'wrong'}),
    );
    await expectLater(
      s.extractOffers(llm, '报价'),
      throwsA(
        isA<LlmException>().having((e) => e.message, 'budget', contains('预算')),
      ),
    );
    expect(run.calls, 1);
    expect(events.single.task, AiTask.offerExtraction);
  });

  test(
    'cancelling import aborts waiting and prevents the next chunk',
    () async {
      final s = device('A');
      addTearDown(s.close);
      final token = AiCancellation();
      final pending = Completer<Map<String, Object?>>();
      var calls = 0;
      final llm = LlmClient(
        const LlmConfig(apiKey: 'test'),
        transport: (_) {
          calls++;
          return pending.future;
        },
      );
      final future = s.extractOffers(llm, '报价\n' * 4000, cancellation: token);
      final expectation = expectLater(future, throwsA(isA<LlmException>()));
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      await expectation;
      pending.complete(response({'offers': []}));
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(s.db.select('SELECT id FROM quotation'), isEmpty);
    },
  );

  test(
    'deadline covers a whole run and closes cancellation listeners',
    () async {
      final token = AiCancellation();
      var aborted = false;
      token.onCancel(() => aborted = true);
      final run = AiRun(
        AiTask.listProposal,
        cancellation: token,
        limits: const AiLimits(timeout: Duration(milliseconds: 20)),
      );
      final pending = Completer<Map<String, Object?>>();
      final llm = LlmClient(
        const LlmConfig(apiKey: 'test'),
        run: run,
        transport: (_) => pending.future,
      );
      await expectLater(
        llm.json('sys', 'data'),
        throwsA(
          isA<LlmException>().having(
            (e) => e.message,
            'timeout',
            contains('超时'),
          ),
        ),
      );
      expect(aborted, isTrue);
      expect(token.isCancelled, isTrue);
      pending.complete(response({}));
    },
  );

  test('oversized source is rejected before any paid call', () async {
    final s = device('A');
    addTearDown(s.close);
    var calls = 0;
    final llm = LlmClient(
      const LlmConfig(apiKey: 'test'),
      transport: (_) async {
        calls++;
        return response({});
      },
    );
    await expectLater(
      s.proposeFromList(llm, 'a' * 60001),
      throwsA(isA<LlmException>()),
    );
    await expectLater(
      s.extractOffers(llm, 'a' * 60001),
      throwsA(isA<LlmException>()),
    );
    await expectLater(
      aiExtractParams(llm, 'computer.ipc', 'a' * 60001),
      throwsA(isA<LlmException>()),
    );
    expect(calls, 0);
  });

  test('request and response limits apply before content acceptance', () async {
    var calls = 0;
    LlmClient client(AiLimits limits) => LlmClient(
      const LlmConfig(apiKey: 'test'),
      run: AiRun(AiTask.clauseReading, limits: limits),
      transport: (_) async {
        calls++;
        return response({'x': 'a' * 200});
      },
    );
    await expectLater(
      client(const AiLimits(maxRequestChars: 10)).json('sys', 'data'),
      throwsA(isA<LlmException>()),
    );
    expect(calls, 0);
    await expectLater(
      client(const AiLimits(maxResponseChars: 100)).json('sys', 'data'),
      throwsA(isA<LlmException>()),
    );
    expect(calls, 1);
  });

  test(
    'spec and parameter tasks reject malformed roots through the same parser',
    () async {
      final model = FakeModel([
        jsonReply({'clauses': 'bad'}),
        jsonReply({'clauses': 'bad'}),
      ]);
      await expectLater(
        aiReadClauses(model.client, 'computer.ipc', [
          const SpecClause(1, '显存两个G', hint: '待读'),
        ]),
        throwsA(isA<LlmException>()),
      );
      final second = FakeModel([
        jsonReply({'clauses': 'bad'}),
        jsonReply({'clauses': 'bad'}),
      ]);
      await expectLater(
        aiExtractParams(second.client, 'computer.ipc', '显存两个G'),
        throwsA(isA<LlmException>()),
      );
      expect(second.requests, hasLength(2));
    },
  );

  test(
    'budget is shared across list extraction and candidate matching',
    () async {
      final s = device('A');
      addTearDown(s.close);
      s.save('product', product('水泵'));
      final run = AiRun(
        AiTask.listProposal,
        limits: const AiLimits(maxCalls: 1),
      );
      final llm = LlmClient(
        const LlmConfig(apiKey: 'test'),
        run: run,
        transport: (_) async => response({
          'items': [
            {'name': '水泵'},
          ],
        }),
      );
      await expectLater(
        s.proposeFromList(llm, '水泵2台'),
        throwsA(isA<LlmException>()),
      );
      expect(run.calls, 1);
      expect(s.db.select('SELECT id FROM project'), isEmpty);
    },
  );
}
