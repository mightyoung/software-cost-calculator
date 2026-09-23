import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/workspace.dart';
import 'package:supplier_app/features/exchange/bundle_sync_page.dart';
import 'package:supplier_app/platform/import_cancellation.dart';

final class _Actions implements WorkspaceBundleActions {
  int prepared = 0, committed = 0, cancelled = 0, exported = 0;
  bool failPrepare = false, failCommit = false;
  Completer<void>? parsing;
  @override
  bool get importNeedsPath => false;
  @override
  Future<WorkspaceBundlePreview> prepareImport({
    String? sourcePath,
    ImportCancellation? cancellation,
  }) async {
    prepared++;
    if (parsing != null) {
      await cancellation?.attach(() async {
        parsing!.complete();
      });
      await parsing!.future;
      cancellation?.check();
    }
    if (failPrepare) throw StateError('corrupt bundle');
    return WorkspaceBundlePreview(
      handle: this,
      jobId: 'job-1',
      sourceName: 'supplier.bundle.zip',
      sourceDigest: List.filled(64, 'a').join(),
      revisionCount: 12,
    );
  }

  @override
  Future<WorkspaceBundlePreview> resumeImport(String jobId) => prepareImport();

  @override
  Future<String> commitImport(WorkspaceBundlePreview preview) async {
    committed++;
    if (failCommit) throw StateError('backup unavailable');
    return '完整同步已一次提交';
  }

  @override
  Future<void> cancelImport(WorkspaceBundlePreview preview) async {
    cancelled++;
  }

  @override
  Future<String> exportBundle() async {
    exported++;
    return '完整同步包已生成并自验';
  }
}

void main() {
  testWidgets(
    'parsing cancellation is acknowledged before two seconds and never commits',
    (tester) async {
      final actions = _Actions()..parsing = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(home: BundleSyncPage(actions: actions)),
      );
      await tester.tap(find.text('选择并预览'));
      await tester.pump();
      expect(find.text('取消解析'), findsOneWidget);
      await tester.tap(find.text('取消解析'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('取消'), findsWidgets);
      expect(actions.committed, 0);
      expect(find.text('备份并提交'), findsNothing);
    },
  );
  testWidgets('failed commit retains preview for retry without cancellation', (
    tester,
  ) async {
    final actions = _Actions()..failCommit = true;
    await tester.pumpWidget(
      MaterialApp(home: BundleSyncPage(actions: actions)),
    );
    await tester.tap(find.text('选择并预览'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('备份并提交'));
    await tester.pumpAndSettle();
    expect(actions.cancelled, 0);
    expect(find.text('重试备份并提交'), findsOneWidget);
    actions.failCommit = false;
    await tester.tap(find.text('重试备份并提交'));
    await tester.pumpAndSettle();
    expect(actions.prepared, 1);
    expect(actions.committed, 2);
    expect(actions.cancelled, 0);
  });
  testWidgets('bundle import previews before explicit commit and can cancel', (
    tester,
  ) async {
    final actions = _Actions();
    await tester.pumpWidget(
      MaterialApp(home: BundleSyncPage(actions: actions)),
    );
    await tester.tap(find.text('选择并预览'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('修订：12'), findsOneWidget);
    expect(actions.committed, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(actions.cancelled, 1);
    expect(actions.committed, 0);
    expect(find.textContaining('没有提交业务数据'), findsOneWidget);
  });

  testWidgets('bundle commit and export report only completed operations', (
    tester,
  ) async {
    final actions = _Actions();
    await tester.pumpWidget(
      MaterialApp(home: BundleSyncPage(actions: actions)),
    );
    await tester.tap(find.text('选择并预览'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('备份并提交'));
    await tester.pumpAndSettle();
    expect(actions.committed, 1);
    expect(find.text('完整同步已一次提交'), findsOneWidget);
    await tester.tap(find.text('生成同步包'));
    await tester.pumpAndSettle();
    expect(actions.exported, 1);
    expect(find.text('完整同步包已生成并自验'), findsOneWidget);
  });

  testWidgets('corrupt bundle is an error and never reaches commit', (
    tester,
  ) async {
    final actions = _Actions()..failPrepare = true;
    await tester.pumpWidget(
      MaterialApp(home: BundleSyncPage(actions: actions)),
    );
    await tester.tap(find.text('选择并预览'));
    await tester.pumpAndSettle();
    expect(find.textContaining('corrupt bundle'), findsOneWidget);
    expect(actions.committed, 0);
  });
}
