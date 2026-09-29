import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/ai/list_to_project.dart';
import 'package:supplier_app/features/ai/material_import_page.dart';
import 'package:supplier_app/features/spec/spec_item_panel.dart';
import 'package:supplier_core/supplier_core.dart';

class TestState extends AppState {
  TestState(super.store, super.dataDir, this.client) : super.test();
  final LlmClient client;
  @override
  Future<LlmClient?> llm() async => client;
  @override
  Future<bool> hasAiKey() async => true;
  @override
  bool get specAi => true;
}

void main() {
  testWidgets('late AI clauses cannot overwrite edits made while waiting', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('clause_stale');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/a.db', device: 'test');
    addTearDown(store.close);
    store.createSpecRequest('测试', [
      SpecItemDraft(
        '工控机',
        '显存不小于2GB',
        specClass: 'computer.ipc',
        clauses: [const SpecClause(1, '显存不小于2GB', hint: '待核对')],
      ),
    ]);
    final id =
        store.db.select('SELECT id FROM spec_item').single['id'] as String;
    final pending = Completer<Map<String, Object?>>();
    final state = TestState(
      store,
      dir,
      LlmClient(
        const LlmConfig(apiKey: 'test'),
        transport: (_) => pending.future,
      ),
    );
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: SpecItemPanel(state: state, itemId: id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('用 AI 读未识别的条款'));
    await tester.pump();
    store.saveClauses(id, [const SpecClause(1, '显存不小于4GB', hint: '待核对')]);
    state.changed();
    await tester.pump();
    pending.complete({
      'choices': [
        {
          'message': {
            'content': jsonEncode({
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
          },
        },
      ],
    });
    await tester.pumpAndSettle();
    expect(clausesOf(store.get('spec_item', id)!).single.text, '显存不小于4GB');
    expect(find.textContaining('未覆盖你的修改'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final offer in [true, false]) {
    testWidgets(
      'cancel ${offer ? "offer import" : "list matching"} prevents later chunks',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('workflow_cancel');
        addTearDown(() => dir.deleteSync(recursive: true));
        final store = Store.open('${dir.path}/a.db', device: 'test');
        addTearDown(store.close);
        final pending = Completer<Map<String, Object?>>();
        var calls = 0;
        final state = TestState(
          store,
          dir,
          LlmClient(
            const LlmConfig(apiKey: 'test'),
            transport: (_) {
              calls++;
              return pending.future;
            },
          ),
        );
        tester.view.physicalSize = const Size(1200, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: offer
                ? MaterialImportPage(state: state)
                : ListToProjectPage(state: state),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '水泵报价\n' * 2000);
        await tester.tap(find.text(offer ? '开始分析' : '开始匹配'));
        await tester.pump();
        expect(calls, 1);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        pending.complete({
          'choices': [
            {
              'message': {
                'content': jsonEncode({offer ? 'offers' : 'items': []}),
              },
            },
          ],
        });
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(find.text(offer ? '开始分析' : '开始匹配'), findsOneWidget);
        expect(store.db.select('SELECT id FROM project'), isEmpty);
        expect(store.db.select('SELECT id FROM quotation'), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
