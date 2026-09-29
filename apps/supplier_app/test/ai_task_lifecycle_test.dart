import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_core/supplier_core.dart';

class _State extends AppState {
  _State(super.store, super.dataDir, this.client) : super.test();
  final LlmClient client;
  @override
  Future<LlmClient?> llm() async => client;
}

void main() {
  late Directory dir;
  late Store store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('ai_task_lifecycle');
    store = Store.open('${dir.path}/business.db', device: 'test');
  });
  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  String writeSupplier(Store s) => s.save('supplier', {
    for (final field in Supplier.fields) field: null,
    'name': '测试供应商',
    'aliases': <String>[],
    'categories': <String>[],
  });

  for (final close in [false, true]) {
    test(
      close
          ? 'closing state aborts active work without late notifications'
          : 'restore invalidates active task and rejects its late response',
      () async {
        final pending = Completer<Map<String, Object?>>();
        final started = Completer<void>();
        final state = _State(
          store,
          dir,
          LlmClient(
            const LlmConfig(apiKey: 'fake'),
            transport: (_) {
              started.complete();
              return pending.future;
            },
          ),
        );
        if (!close) addTearDown(state.dispose);
        final cancellation = AiCancellation();
        var notifications = 0;
        state.addListener(() => notifications++);
        String? id;
        final operation = state.runAiTask(
          AiTask.conversation,
          {'question': '测试问题'},
          (llm) => llm
              .forTask(AiTask.conversation, cancellation: cancellation)
              .complete([
                {'role': 'user', 'content': '测试问题'},
              ]),
          cancellation: cancellation,
          onCreated: (value) => id = value,
        );
        final rejected = expectLater(operation, throwsA(isA<LlmException>()));
        await started.future;
        if (close) {
          state.dispose();
        } else {
          await state.suspendSyncForRestore();
        }
        final beforeLate = notifications;
        await rejected;
        pending.complete({
          'choices': [
            {
              'message': {'content': '晚到回答'},
            },
          ],
        });
        await Future<void>.delayed(Duration.zero);
        if (close) {
          expect(notifications, beforeLate);
          final reopened = _State(
            store,
            dir,
            LlmClient(const LlmConfig(apiKey: 'fake')),
          );
          addTearDown(reopened.dispose);
          expect(reopened.aiTask(id!).status, 'paused');
        } else {
          expect(state.aiTask(id!).status, 'stale');
          expect(() => state.validateAiTask(id!), throwsA(isA<LlmException>()));
          state.finishRestore();
          expect(() => state.validateAiTask(id!), throwsA(isA<LlmException>()));
        }
        expect(store.db.select('SELECT id FROM supplier'), isEmpty);
      },
    );
  }

  test(
    'confirmed action and receipt commit once; a failed action rolls back both',
    () async {
      final state = _State(
        store,
        dir,
        LlmClient(const LlmConfig(apiKey: 'fake')),
      );
      addTearDown(state.dispose);
      await state.runAiTask(AiTask.offerExtraction, {
        'source': 'test',
      }, (_) async => 'draft');
      final id = state.aiTasks.single.id;
      expect(
        () => state.commitAiTask(id, (s) {
          writeSupplier(s);
          throw const FormatException('用户输入无效');
        }),
        throwsFormatException,
      );
      expect(store.db.select('SELECT id FROM supplier'), isEmpty);
      expect(
        store.db.select('SELECT value FROM meta WHERE key=?', [
          'ai_applied:$id',
        ]),
        isEmpty,
      );
      expect(state.aiTask(id).status, 'ready');
      var writes = 0;
      state.commitAiTask(id, (s) {
        writes++;
        writeSupplier(s);
      });
      expect(
        () => state.commitAiTask(id, (s) {
          writes++;
          writeSupplier(s);
        }),
        throwsFormatException,
      );
      expect(writes, 1);
      expect(store.db.select('SELECT id FROM supplier'), hasLength(1));
      expect(state.aiTask(id).status, 'finished');
    },
  );

  test('business receipt reconciles a ready journal after reopening', () async {
    final client = LlmClient(const LlmConfig(apiKey: 'fake'));
    final state = _State(store, dir, client);
    await state.runAiTask(AiTask.offerExtraction, {
      'source': 'test',
    }, (_) async => 'draft');
    final job = state.aiTasks.single;
    // Simulates a crash after the business transaction committed, before the
    // separate task journal could mark this draft finished.
    store.transaction(() {
      writeSupplier(store);
      store.db.execute('INSERT INTO meta(key,value) VALUES(?,?)', [
        'ai_applied:${job.id}',
        job.epoch,
      ]);
    });
    expect(state.aiTask(job.id).status, 'ready');
    state.dispose();
    final reopened = _State(store, dir, client);
    addTearDown(reopened.dispose);
    expect(reopened.aiTasks.single.status, 'finished');
    expect(
      () => reopened.commitAiTask(job.id, writeSupplier),
      throwsFormatException,
    );
    expect(store.db.select('SELECT id FROM supplier'), hasLength(1));
  });
}
