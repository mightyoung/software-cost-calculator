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
  for (final dark in [false, true]) {
    for (final keyboard in [0.0, 260.0]) {
      testWidgets(
        'assistant fits 320px at 2x with keyboard $keyboard dark=$dark',
        (tester) async {
          final dir = Directory.systemTemp.createTempSync('ask_layout');
          final store = Store.open('${dir.path}/a.db', device: 'test');
          final state = AppState.test(store, dir)
            ..saveSetting(
              'ask_history',
              jsonEncode([
                [true, '泵房预算是多少？', false],
                [false, '请核对报价、数量和含税口径。', false],
              ]),
            );
          addTearDown(() {
            state.dispose();
            store.close();
            dir.deleteSync(recursive: true);
            Tokens.dark = false;
          });
          Tokens.dark = dark;
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
          addTearDown(tester.view.reset);
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(2)),
                child: child!,
              ),
              home: Scaffold(body: AskPage(state: state)),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final send = tester.getRect(find.byTooltip('发送'));
          expect(send.bottom, lessThanOrEqualTo(640 - keyboard));
          await tester.enterText(find.byType(TextField), '继续查询');
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final scenario in [0, 1, 2]) {
    final queried = scenario > 0;
    testWidgets('record links require a pre-cleanup verified mark: $scenario', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('ask_link_evidence');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = Store.open('${dir.path}/a.db', device: '测试机');
      addTearDown(store.close);
      final id = store.save('supplier', {
        for (final field in Supplier.fields) field: null,
        'name': '供应商甲',
        'aliases': <String>[],
        'categories': <String>[],
      });
      var calls = 0;
      final state = _TestState(
        store,
        dir,
        LlmClient(
          const LlmConfig(apiKey: 'fake'),
          transport: (_) async {
            calls++;
            if (queried && calls == 1) {
              return {
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content': null,
                      'tool_calls': [
                        {
                          'id': 'get_supplier',
                          'type': 'function',
                          'function': {
                            'name': 'get',
                            'arguments': jsonEncode({
                              'type': 'supplier',
                              'id': id,
                            }),
                          },
                        },
                      ],
                    },
                  },
                ],
              };
            }
            final markId = queried
                ? id
                : '${id.substring(0, 8)}\u0000${id.substring(8)}';
            return {
              'choices': [
                {
                  'message': {
                    'role': 'assistant',
                    'content':
                        '[[supplier:$markId|供应商甲]]${scenario == 2 ? ' [[supplier:${id.substring(0, 8)}\u0000${id.substring(8)}|质量已认证最低价]]' : ''}',
                  },
                },
              ],
            };
          },
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AskPage(state: state)),
        ),
      );
      await tester.enterText(find.byType(TextField), '查供应商');
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      final chip = find.ancestor(
        of: find.text('供应商甲'),
        matching: find.byType(InkWell),
      );
      if (queried) {
        expect(chip, findsOneWidget);
        expect(tester.widget<InkWell>(chip.first).onTap, isNotNull);
        expect(find.text('质量已认证最低价'), findsNothing);
      } else {
        expect(chip, findsNothing);
        expect(find.textContaining('供应商甲'), findsNothing);
        expect(find.textContaining('没有取得可核验'), findsOneWidget);
      }
    });
  }

  test('answer text cannot forge internal record placeholders', () {
    expect(tidyAnswer('\u0000999\u0000'), '999');
    expect(
      tidyAnswer('\u00000\u0000 [[supplier:$_id|甲泵业]]'),
      '0 [[supplier:$_id|甲泵业]]',
    );
  });

  testWidgets('only six recent answers retain evidence in memory', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dir = Directory.systemTemp.createTempSync('ask_evidence_limit');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/a.db', device: '测试机');
    addTearDown(store.close);
    var calls = 0;
    final state = _TestState(
      store,
      dir,
      LlmClient(
        const LlmConfig(apiKey: 'fake'),
        transport: (_) async {
          calls++;
          return {
            'choices': [
              {
                'message': {'role': 'assistant', 'content': '回答$calls'},
              },
            ],
          };
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AskPage(state: state)),
      ),
    );
    for (var i = 1; i <= 7; i++) {
      await tester.enterText(find.byType(TextField), '问题$i');
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
    }
    expect(find.text('查询依据（0 次）'), findsNWidgets(6));
    expect(find.text('历史回答，未保留查询依据'), findsOneWidget);
    expect(find.text('回答1'), findsNothing);
    final saved = jsonDecode(state.setting('ask_history')!) as List;
    expect(saved, hasLength(14));
    expect(saved.every((entry) => (entry as List).length == 3), isTrue);
    expect(jsonEncode(saved), isNot(contains('observations')));
    expect(jsonEncode(saved), isNot(contains('回答1')));
    expect(
      saved
          .where((entry) => (entry as List)[0] == false)
          .every((entry) => (entry[1] as String).contains('没有取得可核验')),
      isTrue,
    );
  });

  testWidgets('query evidence is collapsed, inspectable and never persisted', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('ask_evidence');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/a.db', device: '测试机');
    addTearDown(store.close);
    final project = store.save('project', {
      'code': 'P1',
      'name': '泵房',
      'status': 'active',
      'type': 'market',
      'level': 'A',
      'currency': 'CNY',
      'tax_mode': 'included',
      'markup_rate': '0',
      'customer': null,
      'contract_no': null,
      'contract_amount': null,
      'department': null,
      'leader': null,
      'start_date': null,
      'end_date': null,
      'notes': null,
    });
    var calls = 0;
    String? result;
    final state = _TestState(
      store,
      dir,
      LlmClient(
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
                        'id': 'budget_call',
                        'type': 'function',
                        'function': {
                          'name': 'project_budget',
                          'arguments': jsonEncode({'project_id': project}),
                        },
                      },
                    ],
                  },
                },
              ],
            };
          }
          result =
              ((body['messages'] as List).last as Map)['content'] as String;
          return {
            'choices': [
              {
                'message': {'role': 'assistant', 'content': '成本为 0 元。'},
              },
            ],
          };
        },
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AskPage(state: state)),
      ),
    );
    await tester.enterText(find.byType(TextField), '泵房预算？');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    expect(find.text('查询依据（1 次）'), findsOneWidget);
    expect(find.text(result!), findsNothing);
    await tester.tap(find.text('查询依据（1 次）'));
    await tester.pumpAndSettle();
    expect(find.text('查预算'), findsOneWidget);
    expect(find.textContaining('不等于结论正确'), findsOneWidget);
    await tester.ensureVisible(find.text('查预算'));
    await tester.tap(find.text('查预算'));
    await tester.pumpAndSettle();
    expect(find.text(result!), findsOneWidget);
    expect(result, contains('"cost":"0"'));
    expect(find.text(jsonEncode({'project_id': project})), findsOneWidget);
    final saved = jsonDecode(state.setting('ask_history')!) as List;
    expect(saved, hasLength(2));
    expect(saved.first, [true, '泵房预算？', false]);
    expect(saved.last[0], isFalse);
    expect(saved.last[2], isFalse);
    expect(saved.last[1], contains('本机查询结果'));
    expect(saved.last[1], contains('"cost": "0"'));
    expect(saved.last[1], isNot(contains('成本为 0 元。')));
  });

  testWidgets('old record references are plain text without current evidence', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('ask_old_evidence');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/a.db', device: '测试机');
    addTearDown(store.close);
    final state = AppState.test(store, dir)
      ..saveSetting(
        'ask_history',
        jsonEncode([
          [false, '[[supplier:$_id|旧供应商]]', false],
        ]),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AskPage(state: state)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('旧供应商'), findsOneWidget);
    expect(find.text('历史回答，未保留查询依据'), findsOneWidget);
    expect(find.textContaining('查询依据（'), findsNothing);
    expect(
      find.ancestor(of: find.text('旧供应商'), matching: find.byType(InkWell)),
      findsNothing,
    );
  });

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
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();
    final sent = requests.single['messages'] as List;
    expect(sent, hasLength(2));
    expect(jsonEncode(sent), isNot(contains('旧的私有')));
    expect(find.textContaining('本次回答没有查询本机数据'), findsOneWidget);
  });

  testWidgets(
    'long opted-in history compacts without blocking cancellation or losing originals',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('ask_compaction');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = Store.open('${dir.path}/a.db', device: '测试机');
      addTearDown(store.close);
      final pending = Completer<Map<String, Object?>>();
      final original = List.generate(
        20,
        (i) => [
          [true, '第 $i 次询价：${'泵房设备条件。' * 200}', false],
          [false, '第 $i 次答复：${'需要核对规格。' * 200}', false],
        ],
      ).expand((pair) => pair).toList();
      var calls = 0;
      final state = _TestState(
        store,
        dir,
        LlmClient(
          const LlmConfig(apiKey: 'fake'),
          transport: (_) {
            calls++;
            return pending.future;
          },
        ),
      )..saveSetting('ask_history', jsonEncode(original));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: AskPage(state: state)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('使用近期对话'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '继续核对');
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls, 1);
      await tester.scrollUntilVisible(
        find.textContaining('整理对话上下文'),
        500,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 100,
      );
      expect(find.textContaining('整理对话上下文'), findsOneWidget);
      expect(find.byTooltip('停止'), findsOneWidget);
      await tester.tap(find.byTooltip('停止'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      final saved = jsonDecode(state.setting('ask_history')!) as List;
      expect(saved.take(original.length).toList(), original);
      pending.complete({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': '晚到的整理结果'},
          },
        ],
      });
      await tester.pumpAndSettle();
      expect(find.text('晚到的整理结果'), findsNothing);
    },
  );

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
      await tester.pump();
      await tester.tap(find.byTooltip('发送'));
      await tester.pump();
      final context = jsonEncode(requests.single['messages']);
      expect(context, contains('来自甲泵业'));
      expect(context, isNot(contains('失败的问题')));
      await tester.tap(find.byTooltip('停止'));
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
