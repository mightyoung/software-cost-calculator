import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/core_supplier_workspace.dart';
import 'package:supplier_app/app/workspace.dart';
import 'package:supplier_app/platform/native_file_ports.dart';
import 'package:supplier_app/platform/workspace_factory_native.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  late Directory directory;
  late CoreSupplierWorkspace workspace;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('supplier-workspace-');
    workspace = await openNativeSupplierWorkspace(directory);
  });
  tearDown(() async {
    await workspace.close();
    await directory.delete(recursive: true);
  });
  Map<String, Object?> supplier(String name) => {
    'name': name,
    'aliases': <String>[],
    'categories': <String>[],
    'address': null,
    'notes': null,
  };

  test('workspace persists CRUD and rejects a stale editor', () async {
    final id = await workspace.save('supplier', supplier('原名称'));
    final before = await workspace.read('supplier', id);
    expect(before.heads, hasLength(1));
    await workspace.save(
      'supplier',
      supplier('新名称'),
      id: id,
      expectedHeads: before.heads,
    );
    await expectLater(
      workspace.save(
        'supplier',
        supplier('陈旧表单'),
        id: id,
        expectedHeads: before.heads,
      ),
      throwsA(isA<DomainFailure>()),
    );
    await workspace.close();
    workspace = await openNativeSupplierWorkspace(directory);
    expect((await workspace.list('supplier')).records.single.title, '新名称');
    await workspace.delete(await workspace.read('supplier', id));
    expect((await workspace.read('supplier', id)).status, 'deleted');
  });

  test('search reaches matching records beyond the first page', () async {
    for (var i = 0; i < 51; i++) {
      await workspace.save(
        'supplier',
        supplier('A${i.toString().padLeft(2, '0')}'),
      );
    }
    final id = await workspace.save('supplier', supplier('Z需要寻找'));
    final page = await workspace.list('supplier', search: '寻找');
    expect(page.records.single.id, id);
  });

  test(
    'workspace accepts latest comparison with supplier and contact names',
    () async {
      final result = await workspace.list(
        'quotation',
        filters: {
          'view': 'latest',
          'supplier_name': '供应商',
          'contact_name': '联系人',
        },
      );
      expect(result.records, isEmpty);
    },
  );

  test(
    'workspace exposes every conflict branch and resolves all heads',
    () async {
      final id = await workspace.save('supplier', supplier('原始名称'));
      final initial = (await workspace.read('supplier', id)).heads.single;
      await workspace.coordinator.database.createJob('parallel-supplier');
      for (final name in ['华东分支', '华南分支']) {
        await workspace.coordinator.database.appendStaging(
          'parallel-supplier',
          RevisionEnvelope.create(
            entityType: 'supplier',
            entityId: id,
            parents: [initial],
            kind: 'put',
            payload: supplier(name),
            authoredAt: '2026-09-21T00:00:00.000Z',
            originDeviceId: workspace.records.deviceId,
          ),
        );
      }
      final token = await workspace.coordinator.database.sealJob(
        'parallel-supplier',
        'parallel-decisions',
      );
      await workspace.coordinator.database.registerConfirmation(
        'parallel-event',
        token,
      );
      await workspace.coordinator.commitStaged(
        jobId: 'parallel-supplier',
        expectedPreviewToken: token,
        confirmationEventId: 'parallel-event',
      );

      final conflict = await workspace.read('supplier', id);
      expect(conflict.status, 'conflicted');
      expect(conflict.heads, hasLength(2));
      final branches = await workspace.conflictBranches('supplier', id);
      expect(branches.map((branch) => branch.payload['name']), {
        '华东分支',
        '华南分支',
      });

      await workspace.resolveConflict(conflict, branches.first.payload);
      final resolved = await workspace.read('supplier', id);
      expect(resolved.status, 'active');
      expect(resolved.heads, hasLength(1));
      expect(resolved.title, branches.first.payload['name']);
      await expectLater(
        workspace.resolveConflict(conflict, branches.last.payload),
        throwsA(isA<DomainFailure>()),
      );
    },
  );

  for (final parallelEdit in [false, true]) {
    test(
      'explicit alias set repairs reverse redirects and rejects stale retry (parallel edit: $parallelEdit)',
      () async {
        final a = await workspace.save('supplier', supplier('甲'));
        final b = await workspace.save('supplier', supplier('乙'));
        final beforeA = await workspace.read('supplier', a);
        final beforeB = await workspace.read('supplier', b);
        final db = workspace.coordinator.database;
        await db.createJob('reverse');
        for (final pair in [(beforeA, b), (beforeB, a)]) {
          if (parallelEdit) {
            await db.appendStaging(
              'reverse',
              RevisionEnvelope.create(
                entityType: 'supplier',
                entityId: pair.$1.id,
                parents: pair.$1.heads.toList(),
                kind: 'put',
                payload: supplier('并行编辑'),
                authoredAt: '2026-09-21T00:00:00.000Z',
                originDeviceId: workspace.records.deviceId,
              ),
            );
          }
          await db.appendStaging(
            'reverse',
            RevisionEnvelope.create(
              entityType: 'supplier',
              entityId: pair.$1.id,
              parents: pair.$1.heads.toList(),
              kind: 'redirect',
              payload: {'target_id': pair.$2},
              authoredAt: '2026-09-21T00:00:00.000Z',
              originDeviceId: workspace.records.deviceId,
            ),
          );
        }
        final token = await db.sealJob('reverse', 'decisions');
        await db.registerConfirmation('reverse-event', token);
        await workspace.coordinator.commitStaged(
          jobId: 'reverse',
          expectedPreviewToken: token,
          confirmationEventId: 'reverse-event',
        );
        final affected = [
          await workspace.read('supplier', a),
          await workspace.read('supplier', b),
        ];
        expect(affected.every((record) => record.status != 'active'), isTrue);
        expect(affected.map((record) => record.heads.length), [
          parallelEdit ? 2 : 1,
          parallelEdit ? 2 : 1,
        ]);
        await workspace.repairAliases(
          type: 'supplier',
          records: affected,
          keeperId: a,
          keeperPayload: supplier('明确保留甲'),
        );
        expect((await workspace.read('supplier', a)).title, '明确保留甲');
        for (final before in affected) {
          final after = await workspace.read('supplier', before.id);
          final revision = await db.findRevision(after.heads.single);
          expect(revision!.parents.toSet(), before.heads);
        }
        await expectLater(
          workspace.repairAliases(
            type: 'supplier',
            records: affected,
            keeperId: a,
            keeperPayload: supplier('陈旧'),
          ),
          throwsA(isA<DomainFailure>()),
        );
      },
    );
  }

  test(
    'put delete conflict can explicitly choose delete with all parent heads',
    () async {
      final id = await workspace.save('supplier', supplier('保留历史'));
      final before = await workspace.read('supplier', id);
      final db = workspace.coordinator.database;
      await db.createJob('put-delete');
      for (final kind in ['put', 'delete']) {
        await db.appendStaging(
          'put-delete',
          RevisionEnvelope.create(
            entityType: 'supplier',
            entityId: id,
            parents: before.heads.toList(),
            kind: kind,
            payload: kind == 'put' ? supplier('并行修改') : {},
            authoredAt: '2026-09-21T00:00:00.000Z',
            originDeviceId: workspace.records.deviceId,
          ),
        );
      }
      final token = await db.sealJob('put-delete', 'decisions');
      await db.registerConfirmation('put-delete-event', token);
      await workspace.coordinator.commitStaged(
        jobId: 'put-delete',
        expectedPreviewToken: token,
        confirmationEventId: 'put-delete-event',
      );
      final conflict = await workspace.read('supplier', id);
      expect(conflict.heads, hasLength(2));
      await workspace.delete(conflict);
      final resolved = await workspace.read('supplier', id);
      expect(resolved.status, 'deleted');
      final revision = await db.findRevision(resolved.heads.single);
      expect(revision!.parents.toSet(), conflict.heads);
      await expectLater(
        workspace.delete(conflict),
        throwsA(isA<DomainFailure>()),
      );
    },
  );

  test('contact picker filters by owning supplier', () async {
    final first = await workspace.save('supplier', supplier('甲'));
    final second = await workspace.save('supplier', supplier('乙'));
    for (final owner in [first, second]) {
      await workspace.save('contact', {
        'supplier_id': owner,
        'name': '联系人',
        'phone': '123456',
        'wechat': null,
        'email': null,
        'notes': null,
      });
    }
    final page = await workspace.list(
      'contact',
      filters: {'supplier_id': first},
    );
    expect(page.records, hasLength(1));
    expect(page.records.single.payload['supplier_id'], first);
    expect(await workspace.deletionImpact('supplier', first), 1);
  });

  test('backup receipt points to an actual decodable complete file', () async {
    await workspace.save('supplier', supplier('备份记录'));
    final receipt = await workspace.perform(WorkspaceTask.createBackup);
    final files = await Directory('${directory.path}/backups')
        .list(recursive: true)
        .where((entry) => entry is File && entry.path.endsWith('.backup'))
        .toList();
    expect(files, hasLength(1));
    final summary = await decodeBackup(
      NativeInputSource(files.single as File, displayName: 'backup'),
    );
    expect(receipt.message, contains(summary.digest));
    expect(summary.header.counts['revision'], 1);
  });

  test('business export publishes a workbook that reads back', () async {
    final receipt = await workspace.perform(WorkspaceTask.exportWorkbook);
    final files = await Directory('${directory.path}/exports')
        .list(recursive: true)
        .where((entry) => entry is File && entry.path.endsWith('.xlsx'))
        .toList();
    expect(files, hasLength(1));
    final staging = XlsxStaging(NativeDatabase.memory());
    try {
      final profile = await const BoundedXlsxReader().readVolume(
        NativeInputSource(files.single as File, displayName: '业务报价.xlsx'),
        staging,
      );
      expect(profile.rows, 1);
      expect(receipt.message, contains('0 行'));
    } finally {
      await staging.close();
    }
  });

  test('job history exposes durable source-bound file tasks only', () async {
    await workspace.save('supplier', supplier('本地编辑不属于文件任务'));
    final source = File('${directory.path}/source.bin');
    await source.writeAsBytes([1, 2, 3, 4]);
    final store = JobStore(
      database: workspace.coordinator.database,
      writeLock: workspace.coordinator.writeLock,
      readActiveVersion: workspace.coordinator.readActiveVersion,
    );
    final created = await store.create(
      NativeInputSource(source, displayName: 'source.bin'),
    );
    final history = await workspace.jobHistory();
    expect(history, hasLength(1));
    expect(history.single.id, created.id);
    expect(history.single.state, 'created');
    expect(history.single.sourceLength, 4);
    expect(history.single.sourceDigest, isNull);
  });

  test('unwired file flows never return successful receipts', () async {
    await expectLater(
      workspace.perform(WorkspaceTask.importWorkbook),
      throwsA(isA<WorkspaceUnavailable>()),
    );
    await expectLater(
      workspace.perform(WorkspaceTask.restoreBackup),
      throwsA(isA<WorkspaceUnavailable>()),
    );
  });
}
