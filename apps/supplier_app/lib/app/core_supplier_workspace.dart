import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:supplier_core/supplier_core.dart';

import 'workspace.dart';
import '../platform/restore_workflow.dart';
import '../platform/business_import_workflow_adapter.dart';

/// Widgets operate on revision-backed records, never on writable projections.
class CoreSupplierWorkspace implements SupplierWorkspace {
  CoreSupplierWorkspace({
    required this.coordinator,
    required this.records,
    required this.runTask,
    required this.close,
    required this.restoreNeedsPath,
    required this.createRestoreWorkflow,
    this.bundleActions,
    this.businessImport,
    this.launchContact,
  }) : queries = QueryRepository(coordinator.database);

  final CommitCoordinator coordinator;
  final RecordService records;
  final QueryRepository queries;
  final Future<WorkspaceTaskResult> Function(WorkspaceTask) runTask;
  final Future<void> Function() close;
  @override
  final bool restoreNeedsPath;
  final RestoreWorkflow<SupplierWorkspace> Function(String? sourcePath)
  createRestoreWorkflow;
  @override
  final WorkspaceBundleActions? bundleActions;
  @override
  final BusinessImportWorkflowAdapter? businessImport;
  final Future<void> Function(Uri)? launchContact;
  @override
  String? get readOnlyReason => null;

  Future<T> _read<T>(Future<T> Function() action) =>
      coordinator.writeLock.run(() async {
        // A restore in another tab/process fences this workspace's connection.
        await coordinator.readActiveVersion();
        return coordinator.database.transaction(action);
      });

  @override
  Future<WorkspacePage> list(
    String type, {
    String search = '',
    Map<String, Object?> filters = const {},
    String? cursor,
  }) => _read(() async {
    if (type == 'quotation') {
      final page = await queries.quotations({
        ...filters,
        if (search.trim().isNotEmpty) ...{
          'product_name': search.trim(),
          'text_mode': 'contains',
        },
      }, cursor: cursor);
      return WorkspacePage([
        for (final row in page.items) await _quotation(row),
      ], nextCursor: page.nextCursor);
    }
    if (filters.keys.any((key) => key != 'supplier_id') ||
        (filters.isNotEmpty && type != 'contact')) {
      throw const WorkspaceUnavailable('当前记录类型不支持这些筛选条件。');
    }
    final page = await queries.entities(
      type,
      cursor: cursor,
      search: search.trim().isEmpty ? null : search.trim(),
      supplierId: filters['supplier_id'] as String?,
    );
    return WorkspacePage([
      for (final row in page.items) await _entity(row),
    ], nextCursor: page.nextCursor);
  });

  Future<Set<String>> _heads(String type, String id) async => {
    for (final row in await coordinator.database.rows(
      'SELECT revision_id FROM entity_head WHERE entity_type=? AND entity_id=?',
      [Variable(type), Variable(id)],
    ))
      row.read<String>('revision_id'),
  };

  Future<WorkspaceRecord> _entity(EntityRow row) async => WorkspaceRecord(
    type: row.type,
    id: row.id,
    title: row.name ?? '未能确定名称',
    payload: row.payload ?? const {},
    status: row.relationStatus,
    heads: await _heads(row.type, row.id),
    subtitle: [
      row.payload?['brand'],
      row.payload?['model'],
      row.payload?['phone'],
    ].whereType<String>().where((v) => v.isNotEmpty).join(' · '),
  );

  Future<WorkspaceRecord> _quotation(QuotationRow row) async {
    final payload = row.payload ?? const <String, Object?>{};
    return WorkspaceRecord(
      type: 'quotation',
      id: row.id,
      title: row.values['product_name'] as String? ?? '未能确定产品',
      subtitle: row.values['supplier_name'] as String? ?? '',
      payload: payload,
      status: row.values['relation_status'] as String? ?? 'active',
      heads: await _heads('quotation', row.id),
      missingContext: payload.isEmpty
          ? const []
          : Quotation.fromJson(payload).missingContext,
      comparisonExclusions: row.comparisonExclusions,
    );
  }

  @override
  Future<WorkspaceRecord> read(String type, String id) => _read(() async {
    if (type != 'quotation') {
      final row = await queries.entity(type, id);
      if (row == null) throw const WorkspaceUnavailable('记录不存在。');
      return _entity(row);
    }
    final heads = await _heads(type, id);
    if (heads.isEmpty) throw const WorkspaceUnavailable('记录不存在。');
    if (heads.length > 1) {
      return WorkspaceRecord(
        type: type,
        id: id,
        title: '冲突询价',
        payload: const {},
        heads: heads,
        status: 'conflicted',
      );
    }
    final revision = (await coordinator.database.findRevision(heads.single))!;
    if (revision.kind != 'put') {
      return WorkspaceRecord(
        type: type,
        id: id,
        title: '非活动询价',
        payload: const {},
        heads: heads,
        status: revision.kind == 'delete' ? 'deleted' : 'redirected',
      );
    }
    final page = await queries.quotationHeads(id);
    if (page.items.isEmpty) throw const WorkspaceUnavailable('询价投影缺失，请检查数据库。');
    return _quotation(page.items.single);
  });

  @override
  Future<String> save(
    String type,
    Map<String, Object?> payload, {
    String? id,
    Set<String> expectedHeads = const {},
    String? copyFrom,
    bool allowExplicitClear = false,
  }) {
    if (copyFrom != null) {
      if (type != 'quotation' || id != null) {
        throw ArgumentError('Only a new quotation can be copied');
      }
      return records.copyQuotation(copyFrom, payload);
    }
    if (id != null) {
      return records.correctEntity(
        type,
        id,
        payload,
        expectedHeads: expectedHeads,
        allowExplicitClear: allowExplicitClear,
      );
    }
    return type == 'quotation'
        ? records.createQuotation(payload)
        : records.createEntity(type, payload);
  }

  @override
  Future<int> deletionImpact(String type, String id) async =>
      type == 'quotation' ? 0 : _read(() => queries.referenceImpact(type, id));

  @override
  Future<void> delete(WorkspaceRecord record) =>
      records.deleteEntity(record.type, record.id, record.heads);

  @override
  Future<List<WorkspaceConflictBranch>> conflictBranches(
    String type,
    String id,
  ) => _read(() async {
    final heads = await _heads(type, id);
    if (heads.length < 2) {
      throw const WorkspaceUnavailable('记录已不再冲突，请重新读取。');
    }
    final result = <WorkspaceConflictBranch>[];
    for (final revisionId in heads.toList()..sort()) {
      final revision = await coordinator.database.findRevision(revisionId);
      if (revision == null ||
          revision.entityType != type ||
          revision.entityId != id) {
        throw const WorkspaceUnavailable('冲突分支不完整，无法安全处理。');
      }
      result.add(
        WorkspaceConflictBranch(
          revisionId: revision.revisionId,
          kind: revision.kind,
          payload: revision.payload,
          authoredAt: revision.authoredAt,
          originDeviceId: revision.originDeviceId,
        ),
      );
    }
    return result;
  });

  @override
  Future<void> resolveConflict(
    WorkspaceRecord record,
    Map<String, Object?> completePayload, {
    bool allowExplicitClear = false,
  }) => records.resolve(
    record.type,
    record.id,
    completePayload,
    record.heads,
    allowExplicitClear: allowExplicitClear,
  );

  @override
  Future<void> mergeEntities({
    required String type,
    required WorkspaceRecord source,
    required WorkspaceRecord target,
    required Map<String, Object?> targetPayload,
  }) => records.mergeEntities(type, source.id, target.id, targetPayload, {
    source.id: source.heads,
    target.id: target.heads,
  });

  @override
  Future<List<WorkspaceJob>> jobHistory({int limit = 50}) => _read(() async {
    RangeError.checkValueInInterval(limit, 1, 200, 'limit');
    final rows = await coordinator.database.rows(
      'SELECT j.job_id FROM import_job j JOIN job_input i ON i.job_id=j.job_id ORDER BY j.rowid DESC LIMIT ?',
      [Variable(limit)],
    );
    final store = JobStore(
      database: coordinator.database,
      writeLock: coordinator.writeLock,
      readActiveVersion: coordinator.readActiveVersion,
    );
    final result = <WorkspaceJob>[];
    for (final row in rows) {
      final job = await store.load(row.read<String>('job_id'));
      result.add(
        WorkspaceJob(
          id: job.id,
          state: job.state.name,
          sourceLength: job.sourceLength,
          sourceDigest: job.sourceDigest,
          generation: job.version.generation,
          replacesJobId: job.replacesJobId,
        ),
      );
    }
    return result;
  });

  @override
  Future<void> repairAliases({
    required String type,
    required List<WorkspaceRecord> records,
    required String keeperId,
    required Map<String, Object?> keeperPayload,
  }) {
    if (records.any((record) => record.type != type) ||
        records.map((record) => record.id).toSet().length != records.length) {
      throw ArgumentError('Repair requires distinct records of the same type');
    }
    return this.records.repairAliases(
      type,
      {for (final record in records) record.id},
      keeperId,
      keeperPayload,
      {for (final record in records) record.id: record.heads},
    );
  }

  @override
  RestoreWorkflow<SupplierWorkspace> restoreWorkflow({String? sourcePath}) =>
      createRestoreWorkflow(sourcePath);

  @override
  Future<void> contact(WorkspaceRecord record, String method) async {
    if (!{'phone', 'wechat', 'email'}.contains(method)) {
      throw ArgumentError.value(method);
    }
    final snapshot = record.type == 'quotation'
        ? record.payload['contact_snapshot'] as Map<String, Object?>?
        : record.payload;
    final value = snapshot?[method] as String?;
    if (value == null || value.trim().isEmpty) {
      throw const WorkspaceUnavailable('没有可用的联系方式。');
    }
    if (method == 'wechat') {
      await Clipboard.setData(ClipboardData(text: value));
      return;
    }
    if (launchContact == null) {
      throw const WorkspaceUnavailable('此平台尚未连接拨号或邮件应用。');
    }
    await launchContact!(
      Uri(scheme: method == 'phone' ? 'tel' : 'mailto', path: value),
    );
  }

  @override
  Future<WorkspaceTaskResult> perform(WorkspaceTask task) => runTask(task);
}
