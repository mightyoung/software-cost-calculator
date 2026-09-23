import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/supplier_app.dart';
import 'package:supplier_app/app/workspace.dart';
import 'package:supplier_app/features/exchange/conflict_resolution.dart';
import 'package:supplier_app/features/exchange/job_history.dart';
import 'package:supplier_app/features/records/record_editor.dart';
import 'package:supplier_app/platform/restore_workflow.dart';
import 'package:supplier_app/platform/business_import_workflow_adapter.dart';

const supplierId = '11111111-1111-4111-8111-111111111111';
const productId = '22222222-2222-4222-8222-222222222222';
const quoteId = '33333333-3333-4333-8333-333333333333';

class TestWorkspace implements SupplierWorkspace {
  bool failList = false;
  bool failSave = false;
  bool historical = false;
  bool conflicted = false;
  Map<String, Object?>? saved;
  final tasks = <WorkspaceTask>[];
  final queries = <Map<String, Object?>>[];
  final history = <WorkspaceJob>[];
  @override
  String? get readOnlyReason => null;
  @override
  bool get restoreNeedsPath => false;
  @override
  WorkspaceBundleActions? get bundleActions => null;
  @override
  BusinessImportWorkflowAdapter? get businessImport => null;
  WorkspaceRecord quote() => WorkspaceRecord(
    type: 'quotation',
    id: quoteId,
    title: '紧固件询价',
    subtitle: '上海五金 · M8',
    missingContext: historical ? ['project', 'inquiry_date'] : [],
    status: conflicted ? 'conflicted' : 'active',
    heads: conflicted ? const {'head-a', 'head-b'} : const {},
    payload: {
      'supplier_id': supplierId,
      'product_id': productId,
      'price': '12.340001',
      'currency': 'CNY',
      'tax_mode': 'unknown',
      'unit_snapshot': '件',
      'min_qty': '1',
      'quoted_on': '2026-09-21',
      'contact_id': null,
      'contact_snapshot': null,
      'tax_rate': null,
      'lead_time_days': null,
      'valid_until': null,
      'notes': null,
      'project_name': historical ? null : '办公改造',
      'project_number': null,
      'inquiry_location': null,
      'inquirer_name': '李工',
      'inquiry_precision': historical ? 'unknown' : 'date',
      'inquiry_date': historical ? null : '2026-09-21',
      'inquired_at': null,
      'inquiry_utc_offset_minutes': null,
      'capture_mode': historical ? 'historical' : 'standard',
    },
  );
  @override
  Future<WorkspacePage> list(
    String type, {
    String search = '',
    Map<String, Object?> filters = const {},
    String? cursor,
  }) async {
    queries.add({'type': type, 'search': search, ...filters, 'cursor': cursor});
    if (failList) throw const WorkspaceUnavailable('磁盘读取失败');
    return switch (type) {
      'supplier' => const WorkspacePage([
        WorkspaceRecord(
          type: 'supplier',
          id: supplierId,
          title: '上海五金',
          payload: {'name': '上海五金'},
        ),
      ]),
      'product' => const WorkspacePage([
        WorkspaceRecord(
          type: 'product',
          id: productId,
          title: '螺栓 M8',
          payload: {'name': '螺栓 M8', 'unit': '件'},
        ),
      ]),
      'quotation' => WorkspacePage([
        quote(),
      ], nextCursor: cursor == null ? 'second' : null),
      _ => const WorkspacePage([]),
    };
  }

  @override
  Future<WorkspaceRecord> read(String type, String id) async => quote();
  @override
  Future<String> save(
    String type,
    Map<String, Object?> payload, {
    String? id,
    Set<String> expectedHeads = const {},
    String? copyFrom,
    bool allowExplicitClear = false,
  }) async {
    if (failSave) throw const WorkspaceUnavailable('版本已变化');
    saved = payload;
    return quoteId;
  }

  @override
  Future<int> deletionImpact(String type, String id) async => 2;
  @override
  Future<void> delete(WorkspaceRecord record) async {}
  @override
  Future<void> repairAliases({
    required String type,
    required List<WorkspaceRecord> records,
    required String keeperId,
    required Map<String, Object?> keeperPayload,
  }) async {}
  @override
  Future<List<WorkspaceConflictBranch>> conflictBranches(
    String type,
    String id,
  ) async => [
    WorkspaceConflictBranch(
      revisionId: 'head-a',
      kind: 'put',
      payload: quote().payload,
      authoredAt: '2026-09-20T10:00:00.000Z',
      originDeviceId: '11111111-1111-4111-8111-111111111111',
    ),
    WorkspaceConflictBranch(
      revisionId: 'head-b',
      kind: 'put',
      payload: {...quote().payload, 'price': '13.5'},
      authoredAt: '2026-09-20T11:00:00.000Z',
      originDeviceId: '22222222-2222-4222-8222-222222222222',
    ),
  ];
  @override
  Future<void> resolveConflict(
    WorkspaceRecord record,
    Map<String, Object?> completePayload, {
    bool allowExplicitClear = false,
  }) async {
    saved = completePayload;
  }

  @override
  Future<void> mergeEntities({
    required String type,
    required WorkspaceRecord source,
    required WorkspaceRecord target,
    required Map<String, Object?> targetPayload,
  }) async {}
  @override
  Future<List<WorkspaceJob>> jobHistory({int limit = 50}) async =>
      history.take(limit).toList();
  @override
  RestoreWorkflow<SupplierWorkspace> restoreWorkflow({String? sourcePath}) =>
      throw const WorkspaceUnavailable('测试未连接恢复');
  @override
  Future<void> contact(WorkspaceRecord record, String method) async {}
  @override
  Future<WorkspaceTaskResult> perform(WorkspaceTask task) async {
    tasks.add(task);
    if (task == WorkspaceTask.exportWorkbook) {
      return const WorkspaceTaskResult('', cancelled: true);
    }
    throw const WorkspaceUnavailable('文件接口未连接');
  }
}

Future<void> fill(WidgetTester tester, String key, String value) async {
  final field = find.byKey(ValueKey('field-$key'));
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
}

void main() {
  testWidgets('job history distinguishes waiting and durable completion', (
    tester,
  ) async {
    final workspace = TestWorkspace();
    workspace.history.addAll(const [
      WorkspaceJob(
        id: 'created-job',
        state: 'created',
        sourceLength: 42,
        generation: 7,
      ),
      WorkspaceJob(
        id: 'done-job',
        state: 'committed',
        sourceLength: 128,
        generation: 8,
        sourceDigest: 'abc',
      ),
    ]);
    await tester.pumpWidget(
      MaterialApp(home: JobHistoryPage(workspace: workspace)),
    );
    await tester.pumpAndSettle();
    expect(find.text('等待读取文件'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.textContaining('源文件尚未绑定'), findsOneWidget);
    expect(find.textContaining('源摘要 abc'), findsOneWidget);
  });

  testWidgets(
    'conflict screen requires an explicit branch and resolves all heads',
    (tester) async {
      tester.view.physicalSize = const Size(900, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final workspace = TestWorkspace()..conflicted = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ConflictResolutionPage(
            workspace: workspace,
            conflict: workspace.quote(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, '以此版本为基础解决冲突'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('项目名称：办公改造').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('以此版本为基础解决冲突'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(workspace.saved?['price'], '12.340001');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'standard quote reports missing project and historical detail labels gaps',
    (tester) async {
      final workspace = TestWorkspace()..historical = true;
      await tester.pumpWidget(SupplierApp(workspace: workspace));
      await tester.pumpAndSettle();
      expect(find.textContaining('历史资料：存在缺失信息'), findsOneWidget);
      await tester.tap(find.text('新增报价'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('请填写项目名称或编号'), findsWidgets);
      expect(workspace.saved, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'full quote form preserves decimal and identifiers and saves through workspace',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final workspace = TestWorkspace();
      await tester.pumpWidget(SupplierApp(workspace: workspace));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新增报价'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择供应商 *'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上海五金'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择产品 *'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('螺栓 M8'));
      await tester.pumpAndSettle();
      await fill(tester, 'price', '12.340001');
      await fill(tester, 'quoted_on', '2026-09-21');
      await fill(tester, 'project_number', '000123-A');
      await fill(tester, 'inquirer_name', '李工');
      await fill(tester, 'inquiry_date', '2026-09-20');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(workspace.saved?['price'], '12.340001');
      expect(workspace.saved?['project_number'], '000123-A');
      expect(workspace.saved?['inquired_at'], isNull);
      expect(workspace.saved?['inquiry_precision'], 'date');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow viewport steps and controls stay reachable with scaled text',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final workspace = TestWorkspace();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: RecordEditor(workspace: workspace, type: 'quotation'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第 1 步，共 3 步'), findsOneWidget);
      expect(find.text('保存').hitTestable(), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('第 2 步，共 3 步'), findsOneWidget);
      expect(find.text('请填写项目名称或编号'), findsWidgets);
      expect(find.text('保存').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed reads are errors and retry preserves query and pagination',
    (tester) async {
      final workspace = TestWorkspace()..failList = true;
      await tester.pumpWidget(SupplierApp(workspace: workspace));
      await tester.pumpAndSettle();
      expect(find.text('读取失败'), findsOneWidget);
      expect(find.text('没有符合条件的记录'), findsNothing);
      workspace.failList = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('下一页'));
      await tester.pumpAndSettle();
      expect(workspace.queries.last['cursor'], 'second');
      await tester.enterText(find.byType(TextField), 'M8');
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      expect(workspace.queries.last['search'], 'M8');
      expect(workspace.queries.last['cursor'], isNull);
    },
  );

  testWidgets(
    'file actions distinguish cancellation and failure from success',
    (tester) async {
      final workspace = TestWorkspace();
      await tester.pumpWidget(SupplierApp(workspace: workspace));
      await tester.pumpAndSettle();
      await tester.tap(find.text('文件与备份'));
      await tester.pumpAndSettle();
      final exportButton = find.widgetWithText(OutlinedButton, '导出业务 Excel');
      await tester.ensureVisible(exportButton);
      await tester.tap(exportButton);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('操作已取消，数据未提交。'));
      expect(find.text('操作已取消，数据未提交。'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.widgetWithText(OutlinedButton, '生成完整备份'),
        200,
      );
      await tester.tap(find.widgetWithText(OutlinedButton, '生成完整备份'));
      await tester.pumpAndSettle();
      expect(find.textContaining('操作未完成'), findsOneWidget);
      expect(workspace.tasks, [
        WorkspaceTask.exportWorkbook,
        WorkspaceTask.createBackup,
      ]);
    },
  );
}
