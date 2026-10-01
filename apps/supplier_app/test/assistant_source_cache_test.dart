import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_core/supplier_core.dart';

class _State extends AppState {
  _State(super.store, super.dataDir) : super.test();

  @override
  Future<LlmClient?> llm() async => LlmClient(
    const LlmConfig(apiKey: 'fake'),
    transport: (_) async =>
        throw StateError('Cache recovery must not call a model'),
  );
}

AssistantWebSnapshot _source({String path = 'server'}) =>
    AssistantWebSnapshot.capture(
      url: 'https://catalog.example/$path',
      title: '来源产品',
      fetchedAt: '2026-10-01T00:00:00Z',
      text: '来源产品的原始网页文字。',
      truncated: false,
      jsonLd: [
        jsonEncode({
          '@type': 'Product',
          'name': '来源服务器',
          'brand': '来源品牌',
          'model': 'REAL-8',
          'additionalProperty': [
            {'@type': 'PropertyValue', 'name': 'unit', 'value': '件'},
          ],
          'offers': {
            '@type': 'Offer',
            'price': '100',
            'priceCurrency': 'CNY',
            'seller': {'name': '来源供应商'},
          },
        }),
      ],
    );

void main() {
  late Directory dir;
  late Store store;
  late _State state;
  const input = {'question': '恢复采购来源', 'history': <Object>[]};

  setUp(() {
    dir = Directory.systemTemp.createTempSync('assistant_source_cache');
    store = Store.open('${dir.path}/business.db', device: 'cache-test');
    state = _State(store, dir);
  });
  tearDown(() {
    state.dispose();
    store.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> inJob(Future<void> Function(String) action) async {
    late String jobId;
    await state.runAiTask<void>(
      AiTask.conversation,
      input,
      (_) => action(jobId),
      onCreated: (id) => jobId = id,
    );
  }

  String key(String id) => 'assistant_web_sources:${jsonEncode(id)}';
  void inject(String id, String encoded) => store.db.execute(
    'INSERT INTO meta(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key(id), encoded],
  );
  String persisted(String id) =>
      store.db.select('SELECT value FROM meta WHERE key=?', [
            key(id),
          ]).single['value']
          as String;
  Matcher corruptCache() => throwsA(
    isA<LlmException>().having(
      (e) => e.message,
      'explicit recovery failure',
      contains('不能恢复该任务'),
    ),
  );

  test(
    'paused task restores the exact source identity and re-extracted facts',
    () async {
      final source = _source();
      expect(source.products, hasLength(1));
      late String jobId;
      await expectLater(
        state.runAiTask<void>(AiTask.conversation, input, (_) async {
          state.saveAssistantWebSnapshot(jobId, source);
          throw StateError('Simulated interrupted synthesis');
        }, onCreated: (id) => jobId = id),
        throwsStateError,
      );
      expect(state.aiTask(jobId).status, 'paused');
      await state.runAiTask<void>(AiTask.conversation, input, (_) async {
        final restored = state.assistantWebSnapshots(jobId).single;
        expect(restored.id, source.id);
        expect(restored.digest, source.digest);
        expect(restored.text, source.text);
        expect(restored.products.single.facts, source.products.single.facts);
        expect(restored.products.single.facts['price'], '100');
        expect(restored.products.single.facts['model'], 'REAL-8');
        expect(
          state.createAssistantWebTools(jobId).snapshot(source.id)!.digest,
          source.digest,
        );
      }, resumeId: jobId);
    },
  );

  for (final field in ['products', 'text', 'digest']) {
    test(
      'tampered $field fails recovery without replacing the captured evidence',
      () async {
        await inJob((id) async {
          final raw =
              jsonDecode(jsonEncode(_source().toJson()))
                  as Map<String, dynamic>;
          if (field == 'products') {
            raw['products'][0]['facts']['price'] = '1';
            raw['products'][0]['facts']['model'] = 'Invented';
          } else if (field == 'text') {
            raw['text'] = '${raw['text']} 被修改的原文';
          } else {
            raw['digest'] = '0' * 64;
          }
          final encoded = jsonEncode([raw]);
          inject(id, encoded);
          expect(() => state.assistantWebSnapshots(id), corruptCache());
          expect(() => state.createAssistantWebTools(id), corruptCache());
          expect(
            () => state.saveAssistantWebSnapshot(
              id,
              _source(path: 'replacement'),
            ),
            corruptCache(),
          );
          expect(persisted(id), encoded);
        });
      },
    );
  }

  for (final scenario in [
    'invalid JSON',
    'object instead of list',
    'primitive row',
    'invalid snapshot',
    'more than eight',
    'character limit',
    'UTF-8 byte limit',
  ]) {
    test(
      '$scenario cache fails explicitly instead of silently becoming empty',
      () async {
        await inJob((id) async {
          final encoded = switch (scenario) {
            'invalid JSON' => '[',
            'object instead of list' => '{}',
            'primitive row' => '[42]',
            'invalid snapshot' => '[{}]',
            'more than eight' => jsonEncode(
              List.generate(9, (_) => _source().toJson()),
            ),
            'character limit' => jsonEncode(['a' * (1024 * 1024)]),
            _ => jsonEncode(['中' * (400 * 1024)]),
          };
          if (scenario == 'UTF-8 byte limit') {
            expect(encoded.length, lessThan(1024 * 1024));
            expect(utf8.encode(encoded).length, greaterThan(1024 * 1024));
          }
          inject(id, encoded);
          expect(() => state.assistantWebSnapshots(id), corruptCache());
          expect(() => state.createAssistantWebTools(id), corruptCache());
          expect(persisted(id), encoded);
        });
      },
    );
  }

  test(
    'cache reads and clearing stay isolated to the exact active task',
    () async {
      await inJob((firstId) async {
        final first = _source(), second = _source(path: 'second');
        state.saveAssistantWebSnapshot(firstId, first);
        await inJob((secondId) async {
          expect(state.assistantWebSnapshots(secondId), isEmpty);
          state.saveAssistantWebSnapshot(secondId, second);
          expect(state.assistantWebSnapshots(firstId).single.id, first.id);
          expect(state.assistantWebSnapshots(secondId).single.id, second.id);
          store.db.execute('INSERT INTO meta(key,value) VALUES (?,?)', [
            'unrelated',
            'retained',
          ]);
          state.clearAssistantWebSnapshots(firstId);
          expect(state.assistantWebSnapshots(firstId), isEmpty);
          expect(state.assistantWebSnapshots(secondId).single.id, second.id);
          expect(
            store.db
                .select("SELECT value FROM meta WHERE key='unrelated'")
                .single['value'],
            'retained',
          );
          state.clearAssistantWebSnapshots(firstId);
          expect(state.assistantWebSnapshots(secondId).single.id, second.id);
        });
      });
    },
  );

  test(
    'completed task cannot read or append source evidence outside its active session',
    () async {
      late String jobId;
      await inJob((id) async {
        jobId = id;
        state.saveAssistantWebSnapshot(id, _source());
      });
      final before = persisted(jobId);
      expect(
        () => state.assistantWebSnapshots(jobId),
        throwsA(isA<LlmException>()),
      );
      expect(
        () => state.saveAssistantWebSnapshot(jobId, _source(path: 'late')),
        throwsA(isA<LlmException>()),
      );
      expect(persisted(jobId), before);
    },
  );
}
