import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/ai/ask_page.dart';
import 'package:supplier_core/supplier_core.dart';

class _State extends AppState {
  _State(super.store, super.dataDir, this.client) : super.test();
  final LlmClient client;
  @override
  Future<LlmClient?> llm() async => client;
}

Map<String, Object?> _reply(Map<String, Object?> message) => {
  'choices': [
    {'message': message},
  ],
};
Map<String, Object?> _tool(String name, Map<String, Object?> args) => _reply({
  'tool_calls': [
    {
      'id': 'test-action',
      'type': 'function',
      'function': {'name': name, 'arguments': jsonEncode(args)},
    },
  ],
});

Future<void> _start(
  WidgetTester tester,
  AppState state, {
  void Function(String)? onOpenPage,
  double scale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: AskPage(state: state, onOpenPage: onOpenPage),
      ),
    ),
  );
  await tester.enterText(find.byType(TextField), '执行请求');
  await tester.pump();
  await tester.tap(find.byTooltip('发送'));
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory dir;
  late Store store;
  late String id;
  _State stateFor(Transport transport) => _State(
    store,
    dir,
    LlmClient(const LlmConfig(apiKey: 'fake'), transport: transport),
  );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('assistant_permissions');
    store = Store.open('${dir.path}/data.db', device: 'test');
    id = store.save('supplier', {
      for (final field in Supplier.fields) field: null,
      'name': '原供应商',
      'aliases': <String>[],
      'categories': <String>[],
    });
  });
  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  for (final scenario in ['approve', 'deny', 'stop', 'stale', 'revoked']) {
    testWidgets(
      'write approval $scenario preserves the concrete business boundary',
      (tester) async {
        var requests = 0;
        final state = stateFor(
          (_) async => ++requests == 1
              ? _tool('update_record', {
                  'type': 'supplier',
                  'id': id,
                  'values': {'name': '新供应商'},
                })
              : _reply({'content': '操作处理完毕。'}),
        );
        addTearDown(state.dispose);
        await _start(tester, state);
        expect(find.text('确认修改供应商'), findsOneWidget);
        expect(store.get('supplier', id)!.data['name'], '原供应商');
        expect(find.text('原值：原供应商'), findsOneWidget);
        expect(find.text('新值：新供应商'), findsOneWidget);
        if (scenario == 'stale') {
          store.save('supplier', {
            ...store.get('supplier', id)!.data,
            'name': '其他修改',
          }, id: id);
        }
        if (scenario == 'revoked') {
          state.assistantPermission = AssistantPermission.readOnly;
        }
        await tester.tap(
          find.text(
            scenario == 'deny'
                ? '拒绝'
                : scenario == 'stop'
                ? '停止任务'
                : '确认修改',
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          store.get('supplier', id)!.data['name'],
          scenario == 'approve'
              ? '新供应商'
              : scenario == 'stale'
              ? '其他修改'
              : '原供应商',
        );
        final receipts = store.db.select(
          "SELECT value FROM meta WHERE key LIKE 'assistant_action:%'",
        );
        expect(receipts.length, scenario == 'approve' ? 1 : 0);
      },
    );
  }

  testWidgets('bypass mode saves without a dialog and shows the model answer', (
    tester,
  ) async {
    var requests = 0;
    final state = stateFor(
      (_) async => ++requests == 1
          ? _tool('update_record', {
              'type': 'supplier',
              'id': id,
              'values': {'name': '新供应商'},
            })
          : _reply({'content': '已把名称改为新供应商。'}),
    )..assistantPermission = AssistantPermission.bypass;
    addTearDown(state.dispose);
    await _start(tester, state);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(store.get('supplier', id)!.data['name'], '新供应商');
    expect(find.textContaining('已把名称改为新供应商。'), findsOneWidget);
    expect(find.textContaining('本机查询结果'), findsNothing);
  });

  testWidgets(
    'read-only mode omits writes and rejects model claimed confirmation',
    (tester) async {
      var requests = 0;
      final bodies = <Map<String, Object?>>[];
      final state = stateFor((body) async {
        bodies.add(body);
        return ++requests == 1
            ? _tool('update_record', {
                'type': 'supplier',
                'id': id,
                'values': {'name': '不应保存'},
                'confirmed': true,
              })
            : _reply({'content': '只读权限，未修改。'});
      })..assistantPermission = AssistantPermission.readOnly;
      addTearDown(state.dispose);
      await _start(tester, state);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(store.get('supplier', id)!.data['name'], '原供应商');
      final offered = (bodies.first['tools'] as List).map(
        (t) => t['function']['name'],
      );
      expect(offered, isNot(contains('update_record')));
      expect(offered, isNot(contains('web_search')));
    },
  );

  testWidgets(
    'failed synthesis retains committed actions and durable evidence',
    (tester) async {
      var requests = 0;
      final state = stateFor((_) async {
        if (++requests == 1) {
          return _tool('update_record', {
            'type': 'supplier',
            'id': id,
            'values': {'name': '已保存供应商'},
          });
        }
        throw LlmException('模型暂时不可用');
      });
      addTearDown(state.dispose);
      await _start(tester, state);
      await tester.tap(find.text('确认修改'));
      await tester.pumpAndSettle();
      expect(store.get('supplier', id)!.data['name'], '已保存供应商');
      expect(find.textContaining('本任务已确认保存 1 项操作'), findsOneWidget);
      expect(find.text('已保存：供应商 已保存供应商'), findsOneWidget);
      expect(find.text('查询依据（1 次）'), findsOneWidget);
    },
  );

  testWidgets('stopping synthesis reports writes already committed', (
    tester,
  ) async {
    var requests = 0;
    final pending = Completer<Map<String, Object?>>();
    final state = stateFor(
      (_) async => ++requests == 1
          ? _tool('update_record', {
              'type': 'supplier',
              'id': id,
              'values': {'name': '已保存供应商'},
            })
          : pending.future,
    );
    addTearDown(state.dispose);
    await _start(tester, state);
    await tester.tap(find.text('确认修改'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(store.get('supplier', id)!.data['name'], '已保存供应商');
    await tester.tap(find.byTooltip('停止'));
    await tester.pumpAndSettle();
    expect(find.textContaining('本任务已确认保存 1 项操作'), findsOneWidget);
    pending.complete(_reply({'content': '完成。'}));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('network requests require review of exact outbound query', (
    tester,
  ) async {
    var requests = 0;
    final state = stateFor(
      (_) async => ++requests == 1
          ? _tool('web_search', {'query': '公开技术标准', 'limit': 2})
          : _reply({'content': '用户拒绝联网请求，未查询网络。'}),
    )..assistantWebEnabled = true;
    addTearDown(state.dispose);
    await _start(tester, state);
    expect(find.text('确认联网搜索'), findsOneWidget);
    expect(find.text('公开技术标准'), findsOneWidget);
    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    expect(find.textContaining('用户拒绝联网请求'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'navigation opens advertised app page after completing the answer',
    (tester) async {
      var requests = 0;
      String? opened;
      final state = stateFor(
        (_) async => ++requests == 1
            ? _tool('open_page', {'page': 'settings'})
            : _reply({'content': '准备打开设置。'}),
      );
      addTearDown(state.dispose);
      await _start(tester, state, onOpenPage: (page) => opened = page);
      await tester.pumpAndSettle();
      expect(opened, 'settings');
      expect(state.aiTasks.single.status, 'finished');
    },
  );

  testWidgets('confirmation dialog fits a 320px phone at twice text scale', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var requests = 0;
    final state = stateFor(
      (_) async => ++requests == 1
          ? _tool('update_record', {
              'type': 'supplier',
              'id': id,
              'values': {'name': '供应商新名称，需要明确确认'},
            })
          : _reply({'content': '已拒绝修改。'}),
    );
    addTearDown(state.dispose);
    await _start(tester, state, scale: 2);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('拒绝'));
    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(store.get('supplier', id)!.data['name'], '原供应商');
  });
}
