import 'dart:async';

import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/features/ai/ask_page.dart';
import 'package:supplier_core/supplier_core.dart';

const _id = '546aff01-c05c-4e08-ac41-09ffc126235a';

class _TestState extends AppState {
  _TestState(super.store, super.dataDir, this.client) : super.test();
  final LlmClient client;
  @override
  Future<LlmClient?> llm() async => client;
}

void main() {
  test('answers keep record marks and lose stray ids', () {
    final mark = '[[supplier:$_id|甲泵业]]';
    expect(tidyAnswer('$mark 报价最低（ID $_id），交期 15 天。'), '$mark 报价最低，交期 15 天。');
    expect(tidyAnswer('配电柜更换项目（编号 P-002，ID `$_id`）没有预算行'), '配电柜更换项目没有预算行');
    expect(tidyAnswer('离心水泵，id：`$_id`，单位台'), '离心水泵，单位台');
    final m = recordRef.firstMatch(tidyAnswer('见 $mark'))!;
    expect([m[1], m[2], m[3]], ['supplier', _id, '甲泵业']);
  });

  testWidgets('earlier questions stay until cleared', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ask_history');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/a.db', device: '测试机');
    addTearDown(store.close);
    final state = AppState.test(store, dir)
      ..saveSetting(
        'ask_history',
        jsonEncode([
          [true, '离心泵最低价？', false],
          [false, '目前最低 3,200 元。', false],
        ]),
      );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: AskPage(state: state)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('离心泵最低价？'), findsOneWidget);
    await tester.tap(find.text('清空记录'));
    await tester.pumpAndSettle();
    expect(find.text('离心泵最低价？'), findsNothing);
    expect(state.setting('ask_history'), isNull);
  });

  testWidgets('damaged history entries do not break the page', (tester) async {
    final dir = Directory.systemTemp.createTempSync('ask_bad_history');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/a.db', device: '测试机');
    addTearDown(store.close);
    final state = AppState.test(store, dir)
      ..saveSetting('ask_history', '[[],[true],null,[false,"ok",false]]');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AskPage(state: state)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('ok'), findsOneWidget);
  });

  testWidgets('local history is not sent without explicit opt-in', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('ask_local_history');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/a.db', device: '测试机');
    addTearDown(store.close);
    final requests = <Map<String, Object?>>[];
    final state =
        _TestState(
          store,
          dir,
          LlmClient(
            const LlmConfig(apiKey: 'fake'),
            transport: (body) async {
              requests.add(
                jsonDecode(jsonEncode(body)) as Map<String, Object?>,
              );
              return {
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': '请指定供应商。'},
                  },
                ],
              };
            },
          ),
        )..saveSetting(
          'ask_history',
          jsonEncode([
            [true, '旧的私有问题', false],
            [false, '旧的私有回答', false],
          ]),
        );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AskPage(state: state)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '查供应商');
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    final sent = requests.single['messages'] as List;
    expect(sent, hasLength(2));
    expect(jsonEncode(sent), isNot(contains('旧的私有')));
  });

  testWidgets(
    'follow-ups use completed history and stop releases the composer',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('ask_followup');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = Store.open('${dir.path}/a.db', device: '测试机');
      addTearDown(store.close);
      final requests = <Map<String, Object?>>[];
      final pending = Completer<Map<String, Object?>>();
      final state =
          _TestState(
            store,
            dir,
            LlmClient(
              const LlmConfig(apiKey: 'fake'),
              transport: (body) {
                requests.add(
                  jsonDecode(jsonEncode(body)) as Map<String, Object?>,
                );
                return pending.future;
              },
            ),
          )..saveSetting(
            'ask_history',
            jsonEncode([
              [true, '泵最低价？', false],
              [false, '来自甲泵业。', false],
              [true, '失败的问题', false],
              [false, '网络失败', true],
            ]),
          );
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(body: AskPage(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        isFalse,
      );
      await tester.tap(find.text('使用近期对话'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '这家供应商还报过什么？');
      await tester.tap(find.text('发送'));
      await tester.pump();
      final context = jsonEncode(requests.single['messages']);
      expect(context, contains('来自甲泵业'));
      expect(context, isNot(contains('失败的问题')));
      await tester.tap(find.text('停止'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      expect(find.textContaining('已停止查询'), findsOneWidget);
      pending.complete({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': '晚到的回答'},
          },
        ],
      });
      await tester.pumpAndSettle();
      expect(find.text('晚到的回答'), findsNothing);
    },
  );
}
