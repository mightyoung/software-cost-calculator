import 'dart:io';
import 'dart:convert';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late AiJobStore journal;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ai_recovery');
    journal = AiJobStore.open('${dir.path}/tasks.sqlite');
  });
  tearDown(() {
    journal.close();
    dir.deleteSync(recursive: true);
  });

  test('invalid assistant messages are regenerated on resume', () async {
    final store = Store.open('${dir.path}/business.sqlite', device: 'test');
    addTearDown(store.close);
    for (final invalid in <Map<String, Object?>>[
      {'content': ''},
      {
        'tool_calls': [
          {
            'id': 'a',
            'type': 'function',
            'function': {'name': 'lookup', 'arguments': 12},
          },
        ],
      },
    ]) {
      final id = journal.create(AiTask.conversation, {}).id;
      var session = journal.start(id);
      var calls = 0;
      LlmClient client() => LlmClient(
        const LlmConfig(apiKey: 'test'),
        checkpoint: session,
        transport: (_) async => {
          'choices': [
            {
              'message': ++calls == 1 ? invalid : {'content': '恢复成功'},
            },
          ],
        },
      );
      await expectLater(
        store.ask(client(), '你好'),
        throwsA(isA<LlmException>()),
      );
      expect(journal.get(id).stepCount, 0);
      session.pause();
      session = journal.start(id);
      expect(await store.ask(client(), '你好'), '恢复成功');
      expect(calls, 2);
    }
  });

  test('business export excludes local task data and apply receipts', () {
    final store = Store.open('${dir.path}/business.sqlite', device: 'test');
    addTearDown(store.close);
    store.db.execute('INSERT INTO meta(key,value) VALUES(?,?)', [
      'ai_applied:job',
      'epoch',
    ]);
    journal.create(AiTask.conversation, {
      'private_prompt': 'private task data',
    });
    store.exportTo('${dir.path}/export.sqlite');
    final exported = Store.open('${dir.path}/export.sqlite', device: 'reader');
    addTearDown(exported.close);
    expect(
      exported.db.select("SELECT 1 FROM meta WHERE key LIKE 'ai_applied:%'"),
      isEmpty,
    );
    expect(
      exported.db.select(
        "SELECT name FROM sqlite_master WHERE name IN ('jobs','steps')",
      ),
      isEmpty,
    );
    expect(
      store.db.select("SELECT 1 FROM meta WHERE key='ai_applied:job'"),
      hasLength(1),
    );
  });

  test(
    'live DeepSeek response survives restart without a second request',
    () async {
      final id = journal.create(AiTask.parameterExtraction, {
        'text': 'water pump',
      }).id;
      final session = journal.start(id);
      final client = LlmClient(
        LlmConfig(apiKey: Platform.environment['DEEPSEEK_API_KEY']!),
        checkpoint: session,
      ).forTask(AiTask.parameterExtraction);
      final answer = await client.json(
        'Return JSON with exactly one key name.',
        'name is water pump',
      );
      expect(answer['name'], 'water pump');
      session.pause();
      journal.close();
      journal = AiJobStore.open('${dir.path}/tasks.sqlite');
      final resumed = LlmClient(
        client.config,
        checkpoint: journal.start(id),
        transport: (_) async =>
            throw StateError('Replay must not call the provider'),
      );
      expect(
        await resumed.json(
          'Return JSON with exactly one key name.',
          'name is water pump',
        ),
        answer,
      );
    },
    skip: Platform.environment['DEEPSEEK_API_KEY'] == null
        ? 'Opt-in live provider test'
        : false,
  );

  test('SIGKILL releases owner and preserves completed WAL step', () async {
    final path = '${dir.path}/crashed.sqlite';
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      'test/fixtures/ai_job_crash.dart',
      path,
    ]);
    addTearDown(() => process.kill(ProcessSignal.sigkill));
    final errors = process.stderr.transform(utf8.decoder).join();
    final id = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 90));
    expect(process.kill(ProcessSignal.sigkill), isTrue);
    expect(await process.exitCode, isNot(0));
    expect(await errors, isNot(contains('Unhandled exception')));
    final reopened = AiJobStore.open(path);
    addTearDown(reopened.close);
    expect(reopened.get(id).status, 'paused');
    expect(reopened.start(id).restore({'step': 1})?['content'], 'durable');
  }, timeout: const Timeout(Duration(seconds: 120)));

  test(
    'exclusive owner, epoch, deletion and cancellation reject late writes',
    () {
      expect(
        () => AiJobStore.open('${dir.path}/tasks.sqlite'),
        throwsA(isA<LlmException>()),
      );
      for (final operation in ['cancel', 'delete', 'restore']) {
        final id = journal.create(AiTask.conversation, {}).id;
        final session = journal.start(id);
        if (operation == 'cancel') session.cancellation.cancel();
        if (operation == 'delete') journal.discard(id);
        if (operation == 'restore') journal.invalidateAll();
        expect(
          () => session.record({}, {'content': 'late'}),
          throwsA(isA<LlmException>()),
        );
        session.pause();
      }
    },
  );

  test('changed request invalidates entire saved suffix', () {
    final id = journal.create(AiTask.conversation, {}).id;
    var s = journal.start(id);
    s.record({'step': 1}, {'content': 'first'});
    s.record({'step': 2}, {'content': 'old'});
    s.record({'step': 3}, {'content': 'old tail'});
    s.pause();
    s = journal.start(id);
    expect(s.restore({'step': 1})?['content'], 'first');
    expect(s.restore({'step': 2, 'changed': true}), isNull);
    s.record({'step': 2, 'changed': true}, {'content': 'fresh'});
    expect(s.restore({'step': 3}), isNull);
    expect(journal.get(id).stepCount, 2);
  });

  test(
    'LLM replay skips transport and never stores configured API key',
    () async {
      final id = journal.create(AiTask.parameterExtraction, {}).id;
      var s = journal.start(id);
      var calls = 0;
      LlmClient client() => LlmClient(
        const LlmConfig(apiKey: 'SECRET-NOT-IN-JOURNAL'),
        checkpoint: s,
        transport: (_) async {
          calls++;
          return {
            'choices': [
              {
                'message': {'content': '{"value":42}'},
              },
            ],
          };
        },
      );
      expect(await client().json('system', 'question'), {'value': 42});
      s.pause();
      journal.close();
      journal = AiJobStore.open('${dir.path}/tasks.sqlite');
      s = journal.start(id);
      expect(await client().json('system', 'question'), {'value': 42});
      expect(calls, 1);
      s.ready();
      journal.close();
      for (final file in dir.listSync().whereType<File>()) {
        expect(
          latin1.decode(file.readAsBytesSync()),
          isNot(contains('SECRET-NOT-IN-JOURNAL')),
        );
      }
    },
  );

  test(
    'invalid JSON is discarded so resume can repair instead of replaying failure',
    () async {
      final id = journal.create(AiTask.parameterExtraction, {}).id;
      var s = journal.start(id);
      final bad = LlmClient(
        const LlmConfig(apiKey: 'test'),
        checkpoint: s,
        transport: (_) async => {
          'choices': [
            {
              'message': {'content': 'invalid'},
            },
          ],
        },
      );
      await expectLater(
        bad.json('system', 'input'),
        throwsA(isA<LlmException>()),
      );
      expect(journal.get(id).stepCount, 0);
      s.pause();
      s = journal.start(id);
      final good = LlmClient(
        const LlmConfig(apiKey: 'test'),
        checkpoint: s,
        transport: (_) async => {
          'choices': [
            {
              'message': {'content': '{"ok":true}'},
            },
          ],
        },
      );
      expect(await good.json('system', 'input'), {'ok': true});
    },
  );
  test(
    'completed steps survive reopening and inputs never contain credentials',
    () async {
      final dir = Directory.systemTemp.createTempSync('ai_jobs');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/jobs.sqlite';
      var jobs = AiJobStore.open(path);
      final id = jobs.create(AiTask.offerExtraction, {'source': '水泵2台'}).id;
      var session = jobs.start(id);
      session.record({'model': 'm', 'messages': []}, {'content': '已提取'});
      session.pause('中断');
      jobs.close();
      jobs = AiJobStore.open(path);
      addTearDown(jobs.close);
      expect(jobs.get(id).input['source'], '水泵2台');
      session = jobs.start(id);
      expect(
        session.restore({'model': 'm', 'messages': []})?['content'],
        '已提取',
      );
      expect(session.replayedCalls, 1);
      session.ready();
      expect(jobs.get(id).status, 'ready');
    },
  );
}
