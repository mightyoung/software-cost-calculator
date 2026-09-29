import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/features/ai/material_import_page.dart';
import 'package:supplier_app/features/ai/material_review.dart';
import 'package:supplier_app/features/ai/ai_tasks_page.dart';
import 'package:supplier_app/features/ai/list_to_project.dart';
import 'package:supplier_app/features/ai/list_review.dart';
import 'package:supplier_core/supplier_core.dart';

class _State extends AppState {
  _State(super.store, super.dataDir, this.client) : super.test();
  final LlmClient client;
  @override
  Future<LlmClient?> llm() async => client;
  @override
  Future<bool> hasAiKey() async => true;
}

void main() {
  for (final offer in [true, false]) {
    testWidgets(
      '${offer ? 'offers' : 'list'} draft survives reopening without new model calls',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('ai_import_resume');
        addTearDown(() => dir.deleteSync(recursive: true));
        final store = Store.open('${dir.path}/business.db', device: 'test');
        addTearDown(store.close);
        var calls = 0;
        final client = LlmClient(
          const LlmConfig(apiKey: 'test'),
          transport: (_) async {
            calls++;
            return {
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({
                      offer ? 'offers' : 'items': [
                        if (offer)
                          {
                            'name': '测试水泵',
                            'supplier': '测试供应商',
                            'price': '100',
                            'unit': '台',
                          }
                        else
                          {
                            'name': '测试水泵',
                            'requirements': '清水输送',
                            'qty': '2',
                            'unit': '台',
                            'keywords': ['测试水泵'],
                          },
                      ],
                    }),
                  },
                },
              ],
            };
          },
        );
        final state = _State(store, dir, client);
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        Widget page(AppState state, [String? id]) => MaterialApp(
          home: offer
              ? MaterialImportPage(state: state, resumeJobId: id)
              : ListToProjectPage(state: state, resumeJobId: id),
        );
        await tester.pumpWidget(page(state));
        await tester.pumpAndSettle();
        const source = '测试水泵，清水输送，2台，测试供应商每台100元';
        await tester.enterText(find.byType(TextField), source);
        await tester.tap(find.text(offer ? '开始分析' : '开始匹配'));
        await tester.pumpAndSettle();
        expect(
          find.byType(offer ? MaterialReview : ListReview),
          findsOneWidget,
        );
        final job = state.aiTasks.single;
        expect(job.status, 'ready');
        expect(job.input['source'], source);
        final paidCalls = calls;
        await tester.pumpWidget(const SizedBox());
        state.dispose();
        final reopened = _State(store, dir, client);
        addTearDown(reopened.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: AiTasksPage(state: reopened)),
          ),
        );
        await tester.pumpAndSettle();
        expect(calls, paidCalls);
        expect(find.byType(offer ? MaterialReview : ListReview), findsNothing);
        await tester.tap(find.text('继续'));
        await tester.pumpAndSettle();
        expect(
          find.byType(offer ? MaterialReview : ListReview),
          findsOneWidget,
        );
        expect(calls, paidCalls);
        expect(reopened.aiTasks, hasLength(1));
        expect(store.db.select('SELECT id FROM project'), isEmpty);
        expect(store.db.select('SELECT id FROM quotation'), isEmpty);
        await tester.tap(find.text(offer ? '返回修改' : '返回修改清单'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '$source，修改了需求');
        await tester.tap(find.text(offer ? '开始分析' : '开始匹配'));
        await tester.pumpAndSettle();
        expect(calls, greaterThan(paidCalls));
        expect(reopened.aiTasks, hasLength(2));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
