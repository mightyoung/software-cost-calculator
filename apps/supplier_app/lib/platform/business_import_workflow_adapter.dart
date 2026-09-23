import 'package:supplier_core/supplier_core.dart';

import 'import_cancellation.dart';

/// Platform-owned file selection and durable parsed staging. Widgets use this
/// boundary and core workflows; they never write business tables or revisions.
abstract class BusinessImportWorkflowAdapter {
  BusinessImportWorkflowAdapter({
    required this.exchange,
    required this.deviceId,
  });
  final ExchangeService exchange;
  final String deviceId;
  bool get usesPath;
  Future<InputSource> selectSource(String path);
  Future<XlsxStaging> openStaging(String jobId, {required bool existing});

  Future<BusinessImportSelection> select(
    String path, {
    ImportCancellation? cancellation,
  }) async {
    var source = await selectSource(path);
    source = cancellation?.wrap(source) ?? source;
    final sheets = await const BoundedXlsxReader().sheetNames(source);
    cancellation?.check();
    return BusinessImportSelection(source, sheets);
  }

  Future<BusinessImportSession> prepare(
    BusinessImportSelection selection,
    String sheetName, {
    ImportCancellation? cancellation,
  }) async {
    final source = cancellation?.wrap(selection.source) ?? selection.source;
    final job = await exchange.beginBusiness(source);
    await cancellation?.attach(() async {
      await exchange.cancel(job.id);
    });
    final staging = await openStaging(job.id, existing: false);
    try {
      await exchange.prepareBusiness(
        job.id,
        source,
        staging,
        policy: BusinessWorkbookPolicy(maxDataRows: 100000),
        sheetName: sheetName,
      );
      cancellation?.check();
      await staging.finish({
        ...await staging.profile(),
        'adapter_source_name': selection.source.displayName,
      });
      return BusinessImportSession(
        this,
        job.id,
        staging,
        await staging.profile(),
        null,
        jobState: JobState.validating,
      );
    } catch (_) {
      await staging.close();
      rethrow;
    }
  }

  Future<BusinessImportSession> resume(String jobId) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,200}$').hasMatch(jobId)) {
      throw ArgumentError('无效任务编号');
    }
    final job = await exchange.resume(jobId);
    if (![
      JobState.validating,
      JobState.previewReady,
      JobState.committed,
    ].contains(job.state)) {
      throw const DomainFailure(
        'import_not_resumable',
        '该任务未完成解析或已终止，请重新选择文件创建任务',
      );
    }
    final staging = await openStaging(jobId, existing: true);
    try {
      final profile = await staging.profile();
      final saved = profile['business_mapping'];
      final session = BusinessImportSession(
        this,
        jobId,
        staging,
        profile,
        saved is Map
            ? BusinessMapping.fromJson(saved.cast<String, Object?>())
            : null,
        jobState: job.state,
      );
      if (job.state != JobState.validating) {
        session.confirmation = await exchange.resumeBusinessConfirmation(jobId);
      }
      return session;
    } catch (_) {
      await staging.close();
      rethrow;
    }
  }
}

final class BusinessImportSelection {
  const BusinessImportSelection(this.source, this.sheets);
  final InputSource source;
  final List<String> sheets;
}

class BusinessImportSession {
  BusinessImportSession(
    this.adapter,
    this.jobId,
    this.staging,
    this.profile,
    this.mapping, {
    required this.jobState,
  });
  final BusinessImportWorkflowAdapter adapter;
  final String jobId;
  final XlsxStaging staging;
  final Map<String, Object?> profile;
  BusinessMapping? mapping;
  JobState jobState;
  BusinessConfirmation? confirmation;
  BusinessImportWorkflow get workflow => BusinessImportWorkflow(
    exchange: adapter.exchange,
    jobId: jobId,
    staging: staging,
    mapping: mapping!,
    deviceId: adapter.deviceId,
  );
  Future<List<StagedXlsxCell>> cells(int row) async {
    final result = <StagedXlsxCell>[];
    var cursor = 0;
    while (true) {
      final page = await staging.cellsPage(row, afterColumn: cursor);
      if (page.isEmpty) return result;
      // Display mapping columns only, with an explicit bounded UI width.
      result.addAll(page);
      if (result.length >= 100) return result.take(100).toList();
      cursor = page.last.column;
    }
  }

  Future<void> setMapping(BusinessMapping next) async {
    if (jobState != JobState.validating || mapping != null) {
      throw const DomainFailure(
        'mapping_already_confirmed',
        '映射已确认；调整映射请建立新任务',
      );
    }
    await staging.finish({...profile, 'business_mapping': next.configuration});
    mapping = next;
  }

  Future<BusinessImportSummary> summary() => workflow.summary();
  Future<CommitReceipt> confirm() async {
    confirmation ??= await workflow.seal();
    jobState = JobState.previewReady;
    final receipt = await adapter.exchange.commit(confirmation!);
    jobState = JobState.committed;
    return receipt;
  }

  Future<void> cancel() async {
    await adapter.exchange.cancel(jobId);
    jobState = JobState.cancelled;
  }

  Future<void> close() => staging.close();
}
