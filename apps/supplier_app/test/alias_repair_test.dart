import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/workspace.dart';
import 'package:supplier_app/features/exchange/alias_repair.dart';

class RepairWorkspace implements SupplierWorkspace {
  bool failMerge = false;
  bool conflict = false;
  int writes = 0;
  int reads = 0;
  Set<String>? submittedHeads;
  Map<String, Object?>? submittedPayload;
  List<WorkspaceRecord>? repairedRecords;
  final queries = <String>[];
  @override
  String? readOnlyReason;

  WorkspaceRecord record(String id) => WorkspaceRecord(
    type: 'supplier',
    id: id,
    title: id == 'source' ? '来源公司' : '保留公司',
    status: conflict ? 'conflicted' : 'active',
    heads: {'$id-v$reads'},
    payload: {
      'name': id == 'source' ? '来源公司' : '保留公司',
      'notes': null,
      'code': '0007',
    },
  );
  @override
  Future<WorkspacePage> list(
    String type, {
    String search = '',
    Map<String, Object?> filters = const {},
    String? cursor,
  }) async {
    queries.add(search);
    return WorkspacePage([record('source'), record('keeper')]);
  }

  @override
  Future<WorkspaceRecord> read(String type, String id) async {
    reads++;
    return record(id);
  }

  @override
  Future<int> deletionImpact(String type, String id) async => 3;
  @override
  Future<void> repairAliases({
    required String type,
    required List<WorkspaceRecord> records,
    required String keeperId,
    required Map<String, Object?> keeperPayload,
  }) async {
    writes++;
    repairedRecords = records;
    submittedPayload = keeperPayload;
    if (failMerge) throw const WorkspaceUnavailable('stale_heads');
  }

  @override
  Future<void> mergeEntities({
    required String type,
    required WorkspaceRecord source,
    required WorkspaceRecord target,
    required Map<String, Object?> targetPayload,
  }) async {
    writes++;
    submittedHeads = source.heads;
    submittedPayload = targetPayload;
    if (failMerge) throw const WorkspaceUnavailable('stale_heads');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> tap(WidgetTester tester, String label) async {
  final finder = find.text(label).last;
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> open(WidgetTester tester, RepairWorkspace workspace) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<bool>(
              MaterialPageRoute(
                builder: (_) =>
                    AliasRepairPage(workspace: workspace, type: 'supplier'),
              ),
            ),
            child: const Text('打开修复'),
          ),
        ),
      ),
    ),
  );
  await tap(tester, '打开修复');
}

Future<void> selectPair(WidgetTester tester) async {
  await tap(tester, '选择来源记录');
  await tap(tester, '来源公司');
  await tap(tester, '选择保留记录');
  expect(find.text('来源公司'), findsNothing);
  await tap(tester, '保留公司');
  await tap(tester, '核对最新内容与影响');
}

void main() {
  testWidgets(
    'explicit group repair accepts conflicted records and submits all fresh heads',
    (tester) async {
      final workspace = RepairWorkspace()..conflict = true;
      await open(tester, workspace);
      await tap(tester, '修复一组异常关联');
      await selectPair(tester);
      await tap(tester, '我已核对来源、保留记录和完整内容，确认建立关联');
      await tap(tester, '确认关联修复');
      expect(workspace.writes, 1);
      expect(workspace.repairedRecords!.map((r) => r.heads), [
        {'source-v1'},
        {'keeper-v2'},
      ]);
      expect(workspace.submittedPayload!['name'], '保留公司');
    },
  );
  testWidgets(
    'requires explicit selections and confirmation; submits complete keeper and read heads',
    (tester) async {
      final workspace = RepairWorkspace();
      await open(tester, workspace);
      expect(workspace.writes, 0);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await selectPair(tester);
      expect(find.textContaining('3 条当前引用'), findsOneWidget);
      expect(find.textContaining('"notes": null'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await tap(tester, '我已核对来源、保留记录和完整内容，确认建立关联');
      await tap(tester, '确认关联修复');
      expect(workspace.writes, 1);
      expect(workspace.submittedHeads, {'source-v1'});
      expect(workspace.submittedPayload, {
        'name': '保留公司',
        'notes': null,
        'code': '0007',
      });
      expect(find.text('打开修复'), findsOneWidget);
    },
  );

  testWidgets(
    'stale failure keeps choices and requires refreshed preview plus new consent',
    (tester) async {
      final workspace = RepairWorkspace()..failMerge = true;
      await open(tester, workspace);
      await selectPair(tester);
      await tap(tester, '我已核对来源、保留记录和完整内容，确认建立关联');
      await tap(tester, '确认关联修复');
      expect(find.textContaining('stale_heads'), findsOneWidget);
      expect(find.textContaining('来源公司\nsource'), findsOneWidget);
      expect(find.textContaining('保留公司\nkeeper'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      workspace.failMerge = false;
      await tap(tester, '核对最新内容与影响');
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        false,
      );
      await tap(tester, '我已核对来源、保留记录和完整内容，确认建立关联');
      await tap(tester, '确认关联修复');
      expect(workspace.submittedHeads, {'source-v3'});
      expect(workspace.writes, 2);
    },
  );

  testWidgets(
    'mobile scroll and search work; changed conflicting record blocks preview',
    (tester) async {
      tester.view.physicalSize = const Size(390, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final workspace = RepairWorkspace();
      await open(tester, workspace);
      await tap(tester, '选择来源记录');
      await tester.enterText(find.byType(TextField), '公司');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(workspace.queries.last, '公司');
      await tap(tester, '来源公司');
      await tap(tester, '选择保留记录');
      await tap(tester, '保留公司');
      workspace.conflict = true;
      await tap(tester, '核对最新内容与影响');
      expect(find.textContaining('无冲突的有效记录'), findsOneWidget);
      expect(workspace.writes, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('read-only workspace cannot submit', (tester) async {
    final workspace = RepairWorkspace()..readOnlyReason = '只读模式';
    await open(tester, workspace);
    await selectPair(tester);
    await tap(tester, '我已核对来源、保留记录和完整内容，确认建立关联');
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    expect(workspace.writes, 0);
  });
}
