import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/features/ai/ask_page.dart';
import 'package:supplier_app/features/spec/spec_item_panel.dart';
import 'package:supplier_core/supplier_core.dart';

class _State extends AppState {
  _State(super.store, super.dataDir, this.client) : super.test();
  final LlmClient client;
  @override
  Future<LlmClient?> llm() async => client;
  @override
  bool get specAi => true;
}

Map<String, Object?> _reply(String content) => {
  'choices': [
    {
      'message': {'role': 'assistant', 'content': content},
    },
  ],
};

void main() {
  testWidgets(
    'resuming conversation replays model steps but refreshes business evidence',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('answer_resume');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = Store.open('${dir.path}/business.db', device: 'test');
      addTearDown(store.close);
      final supplier = store.save('supplier', {
        for (final field in Supplier.fields) field: null,
        'name': '旧供应商名称',
        'aliases': <String>[],
        'categories': <String>[],
      });
      final pending = Completer<Map<String, Object?>>();
      var calls = 0;
      String? resumedToolResult;
      final client = LlmClient(
        const LlmConfig(apiKey: 'fake'),
        transport: (body) async {
          calls++;
          if (calls == 1) {
            return {
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content': null,
                    'tool_calls': [
                      {
                        'id': 'supplier_lookup',
                        'type': 'function',
                        'function': {
                          'name': 'get',
                          'arguments': jsonEncode({
                            'type': 'supplier',
                            'id': supplier,
                          }),
                        },
                      },
                    ],
                  },
                },
              ],
            };
          }
          if (calls == 2) return pending.future;
          final messages = body['messages'] as List;
          resumedToolResult = (messages.last as Map)['content'] as String;
          return _reply('已核对新供应商名称。');
        },
      );
      final state = _State(store, dir, client);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AskPage(state: state)),
        ),
      );
      await tester.enterText(find.byType(TextField), '查询这家供应商');
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();
      expect(calls, 2);
      final job = state.aiTasks.single;
      expect(job.stepCount, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      state.dispose();
      pending.complete(_reply('过时回答'));
      await tester.pump();
      store.save('supplier', {
        ...store.get('supplier', supplier)!.data,
        'name': '新供应商名称',
      }, id: supplier);
      final reopened = _State(store, dir, client);
      addTearDown(reopened.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AskPage(state: reopened, resumeJobId: job.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 3);
      expect(resumedToolResult, contains('新供应商名称'));
      expect(resumedToolResult, isNot(contains('旧供应商名称')));
      expect(find.text('已核对新供应商名称。'), findsOneWidget);
      expect(find.textContaining('本机查询结果'), findsNothing);
      expect(find.text('旧供应商名称'), findsNothing);
      expect(find.text('过时回答'), findsNothing);
      expect(reopened.aiTask(job.id).status, 'finished');
      expect(tester.takeException(), isNull);
    },
  );

  for (final changed in [true, false]) {
    testWidgets(
      changed
          ? 'changed clauses reject a saved draft before another model call'
          : 'unchanged clause draft resumes and applies with a duplicate-proof receipt',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('clause_resume');
        addTearDown(() => dir.deleteSync(recursive: true));
        final store = Store.open('${dir.path}/business.db', device: 'test');
        addTearDown(store.close);
        const clauses = [SpecClause(1, '显存不小于2GB', hint: '待核对')];
        store.createSpecRequest('测试', [
          SpecItemDraft(
            '工控机',
            '显存不小于2GB',
            specClass: 'computer.ipc',
            clauses: clauses,
          ),
        ]);
        final itemId =
            store.db.select('SELECT id FROM spec_item').single['id'] as String;
        var calls = 0;
        final client = LlmClient(
          const LlmConfig(apiKey: 'fake'),
          transport: (_) async {
            calls++;
            return _reply(
              jsonEncode({
                'clauses': [
                  {
                    'n': 1,
                    'constraints': [
                      {
                        'property': 'gpu.mem',
                        'op': 'ge',
                        'value': '2GB',
                        'evidence': '显存不小于2GB',
                      },
                    ],
                  },
                ],
              }),
            );
          },
        );
        final state = _State(store, dir, client);
        await state.runAiTask(AiTask.clauseReading, {
          'itemId': itemId,
          'classCode': 'computer.ipc',
          'clauses': [for (final c in clauses) c.toJson()],
        }, (llm) => aiReadClauses(llm, 'computer.ipc', clauses));
        final job = state.aiTasks.single;
        expect(job.status, 'ready');
        expect(calls, 1);
        state.dispose();
        if (changed) {
          store.saveClauses(itemId, [
            const SpecClause(1, '显存不小于4GB', hint: '待核对'),
          ]);
        }
        final reopened = _State(store, dir, client);
        addTearDown(reopened.dispose);
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SpecItemPanel(
                state: reopened,
                itemId: itemId,
                resumeJobId: job.id,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(calls, 1);
        final saved = clausesOf(store.get('spec_item', itemId)!).single;
        if (changed) {
          expect(saved.text, '显存不小于4GB');
          expect(saved.constraints, isEmpty);
          expect(find.textContaining('任务输入已变化'), findsOneWidget);
          expect(reopened.aiTask(job.id).status, 'ready');
        } else {
          expect(saved.constraints.single.property, 'gpu.mem');
          expect(reopened.aiTask(job.id).status, 'finished');
          expect(
            store.db.select('SELECT value FROM meta WHERE key=?', [
              'ai_applied:${job.id}',
            ]),
            hasLength(1),
          );
          var duplicateRan = false;
          expect(
            () => reopened.commitAiTask(job.id, (_) => duplicateRan = true),
            throwsFormatException,
          );
          expect(duplicateRan, isFalse);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
