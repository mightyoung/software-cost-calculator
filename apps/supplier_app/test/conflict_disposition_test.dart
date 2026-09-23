import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/workspace.dart';
import 'package:supplier_app/features/exchange/conflict_resolution.dart';
import 'package:supplier_app/features/query/records_page.dart';

import 'alias_repair_test.dart' show RepairWorkspace, tap;

class DispositionWorkspace extends RepairWorkspace {
  String kind = 'delete';
  bool parallelRedirect = false;
  @override
  WorkspaceRecord record(String id) => parallelRedirect && id == 'source'
      ? const WorkspaceRecord(
          type: 'supplier',
          id: 'source',
          title: '并行关联',
          payload: {},
          status: 'parallelRedirect',
          heads: {'put-head', 'other-head'},
        )
      : super.record(id);
  WorkspaceRecord? deleted;
  @override
  Future<List<WorkspaceConflictBranch>> conflictBranches(
    String type,
    String id,
  ) async => [
    WorkspaceConflictBranch(
      revisionId: 'put-head',
      kind: 'put',
      payload: record(id).payload,
      authoredAt: '2026-09-22',
      originDeviceId: 'local',
    ),
    WorkspaceConflictBranch(
      revisionId: 'other-head',
      kind: kind,
      payload: kind == 'redirect' ? {'target_id': 'keeper'} : {},
      authoredAt: '2026-09-22',
      originDeviceId: 'remote',
    ),
  ];
  @override
  Future<void> delete(WorkspaceRecord record) async {
    deleted = record;
  }
}

void main() {
  testWidgets('parallel redirect detail exposes conflict resolution', (
    tester,
  ) async {
    final workspace = DispositionWorkspace()
      ..kind = 'redirect'
      ..parallelRedirect = true;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordDetailPage(
          workspace: workspace,
          record: const WorkspaceRecord(
            type: 'supplier',
            id: 'source',
            title: '并行关联',
            payload: {},
            status: 'parallelRedirect',
            heads: {'put-head', 'other-head'},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tap(tester, '处理冲突');
    expect(find.byType(ConflictResolutionPage), findsOneWidget);
    expect(find.text('关联至 keeper'), findsOneWidget);
    expect(workspace.writes, 0);
  });
  Future<void> open(WidgetTester tester, DispositionWorkspace workspace) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ConflictResolutionPage(
          workspace: workspace,
          conflict: const WorkspaceRecord(
            type: 'supplier',
            id: 'source',
            title: '冲突',
            payload: {},
            status: 'conflicted',
            heads: {'put-head', 'other-head'},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'delete branch requires explicit final confirmation and preserves all heads',
    (tester) async {
      final workspace = DispositionWorkspace();
      await open(tester, workspace);
      await tap(tester, '已删除分支');
      await tap(tester, '以此版本为基础解决冲突');
      expect(workspace.deleted, isNull);
      await tap(tester, '确认删除');
      expect(workspace.deleted!.heads, {'put-head', 'other-head'});
    },
  );
  testWidgets('redirect branch is distinct and opens explicit keeper repair', (
    tester,
  ) async {
    final workspace = DispositionWorkspace()..kind = 'redirect';
    await open(tester, workspace);
    expect(find.text('已删除分支'), findsNothing);
    await tap(tester, '关联至 keeper');
    await tap(tester, '以此版本为基础解决冲突');
    expect(find.text('关联修复'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(workspace.writes, 0);
    await tap(tester, '核对最新内容与影响');
    await tap(tester, '我已核对来源、保留记录和完整内容，确认建立关联');
    await tap(tester, '确认关联修复');
    expect(workspace.repairedRecords!.map((r) => r.id), ['source', 'keeper']);
    expect(workspace.submittedPayload!['name'], '保留公司');
  });
}
