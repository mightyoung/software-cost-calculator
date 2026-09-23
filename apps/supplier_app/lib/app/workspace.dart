import '../platform/restore_workflow.dart';
import '../platform/import_cancellation.dart';
import '../platform/business_import_workflow_adapter.dart';

/// The UI boundary. Implementations own persistence, revision creation, file
/// pickers and platform actions; widgets never write projections directly.
abstract interface class SupplierWorkspace {
  String? get readOnlyReason;
  bool get restoreNeedsPath;

  Future<WorkspacePage> list(
    String type, {
    String search = '',
    Map<String, Object?> filters = const {},
    String? cursor,
  });
  Future<WorkspaceRecord> read(String type, String id);
  Future<String> save(
    String type,
    Map<String, Object?> payload, {
    String? id,
    Set<String> expectedHeads = const {},
    String? copyFrom,
    bool allowExplicitClear = false,
  });
  Future<int> deletionImpact(String type, String id);
  Future<void> delete(WorkspaceRecord record);
  Future<List<WorkspaceConflictBranch>> conflictBranches(
    String type,
    String id,
  );
  Future<void> resolveConflict(
    WorkspaceRecord record,
    Map<String, Object?> completePayload, {
    bool allowExplicitClear = false,
  });
  Future<void> mergeEntities({
    required String type,
    required WorkspaceRecord source,
    required WorkspaceRecord target,
    required Map<String, Object?> targetPayload,
  });
  Future<List<WorkspaceJob>> jobHistory({int limit = 50});
  Future<void> repairAliases({
    required String type,
    required List<WorkspaceRecord> records,
    required String keeperId,
    required Map<String, Object?> keeperPayload,
  });
  RestoreWorkflow<SupplierWorkspace> restoreWorkflow({String? sourcePath});
  WorkspaceBundleActions? get bundleActions;
  BusinessImportWorkflowAdapter? get businessImport;
  Future<void> contact(WorkspaceRecord record, String method);

  /// The platform adapter owns the user-visible file workflow and must only
  /// return a receipt after the requested operation actually completes.
  Future<WorkspaceTaskResult> perform(WorkspaceTask task);
}

class WorkspacePage {
  const WorkspacePage(this.records, {this.nextCursor});
  final List<WorkspaceRecord> records;
  final String? nextCursor;
}

class WorkspaceRecord {
  const WorkspaceRecord({
    required this.type,
    required this.id,
    required this.title,
    required this.payload,
    this.subtitle = '',
    this.heads = const {},
    this.missingContext = const [],
    this.comparisonExclusions = const [],
    this.status = 'active',
  });
  final String type, id, title, subtitle, status;
  final Map<String, Object?> payload;
  final Set<String> heads;
  final List<String> missingContext, comparisonExclusions;
}

class WorkspaceConflictBranch {
  const WorkspaceConflictBranch({
    required this.revisionId,
    required this.kind,
    required this.payload,
    required this.authoredAt,
    required this.originDeviceId,
  });
  final String revisionId, kind, authoredAt, originDeviceId;
  final Map<String, Object?> payload;
}

class WorkspaceJob {
  const WorkspaceJob({
    required this.id,
    required this.state,
    required this.sourceLength,
    required this.generation,
    this.sourceDigest,
    this.replacesJobId,
  });
  final String id, state;
  final int sourceLength, generation;
  final String? sourceDigest, replacesJobId;
  bool get terminal =>
      const {'committed', 'cancelled', 'failed'}.contains(state);
}

class WorkspaceBundlePreview {
  const WorkspaceBundlePreview({
    required this.handle,
    required this.jobId,
    required this.sourceName,
    required this.sourceDigest,
    required this.revisionCount,
  });
  final Object handle;
  final String jobId, sourceName, sourceDigest;
  final int revisionCount;
}

abstract interface class WorkspaceBundleActions {
  bool get importNeedsPath;
  Future<WorkspaceBundlePreview> prepareImport({
    String? sourcePath,
    ImportCancellation? cancellation,
  });
  Future<WorkspaceBundlePreview> resumeImport(String jobId);
  Future<String> commitImport(WorkspaceBundlePreview preview);
  Future<void> cancelImport(WorkspaceBundlePreview preview);
  Future<String> exportBundle();
}

enum WorkspaceTask {
  importWorkbook,
  exportWorkbook,
  createBackup,
  restoreBackup,
}

class WorkspaceTaskResult {
  const WorkspaceTaskResult(this.message, {this.cancelled = false});
  final String message;
  final bool cancelled;
}

class WorkspaceUnavailable implements Exception {
  const WorkspaceUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A safe startup surface until the platform adapter has opened a durable
/// database. It does not supply sample records or simulate successful writes.
class UnavailableWorkspace implements SupplierWorkspace {
  const UnavailableWorkspace([this.readOnlyReason = '本地数据库尚未连接，请检查存储能力后重试。']);
  @override
  final String readOnlyReason;
  @override
  bool get restoreNeedsPath => false;
  @override
  WorkspaceBundleActions? get bundleActions => null;
  @override
  BusinessImportWorkflowAdapter? get businessImport => null;
  Never _unavailable() => throw WorkspaceUnavailable(readOnlyReason);
  @override
  Future<WorkspacePage> list(
    String type, {
    String search = '',
    Map<String, Object?> filters = const {},
    String? cursor,
  }) async => _unavailable();
  @override
  Future<WorkspaceRecord> read(String type, String id) async => _unavailable();
  @override
  Future<String> save(
    String type,
    Map<String, Object?> payload, {
    String? id,
    Set<String> expectedHeads = const {},
    String? copyFrom,
    bool allowExplicitClear = false,
  }) async => _unavailable();
  @override
  Future<int> deletionImpact(String type, String id) async => _unavailable();
  @override
  Future<void> delete(WorkspaceRecord record) async => _unavailable();
  @override
  Future<List<WorkspaceConflictBranch>> conflictBranches(
    String type,
    String id,
  ) async => _unavailable();
  @override
  Future<void> resolveConflict(
    WorkspaceRecord record,
    Map<String, Object?> completePayload, {
    bool allowExplicitClear = false,
  }) async => _unavailable();
  @override
  Future<void> mergeEntities({
    required String type,
    required WorkspaceRecord source,
    required WorkspaceRecord target,
    required Map<String, Object?> targetPayload,
  }) async => _unavailable();
  @override
  Future<List<WorkspaceJob>> jobHistory({int limit = 50}) async =>
      _unavailable();
  @override
  Future<void> repairAliases({
    required String type,
    required List<WorkspaceRecord> records,
    required String keeperId,
    required Map<String, Object?> keeperPayload,
  }) async => _unavailable();
  @override
  RestoreWorkflow<SupplierWorkspace> restoreWorkflow({String? sourcePath}) =>
      _unavailable();
  @override
  Future<void> contact(WorkspaceRecord record, String method) async =>
      _unavailable();
  @override
  Future<WorkspaceTaskResult> perform(WorkspaceTask task) async =>
      _unavailable();
}
