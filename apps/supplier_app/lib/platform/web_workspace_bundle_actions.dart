import '../app/workspace.dart';
import 'bundle_workflow.dart';
import 'web_bundle_workflow.dart';
import 'import_cancellation.dart';

final class WebWorkspaceBundleActions implements WorkspaceBundleActions {
  const WebWorkspaceBundleActions(this.workflow);

  final WebBundleWorkflow workflow;

  @override
  bool get importNeedsPath => false;

  @override
  Future<WorkspaceBundlePreview> prepareImport({
    String? sourcePath,
    ImportCancellation? cancellation,
  }) async {
    final preview = await workflow.pickAndPrepare(cancellation: cancellation);
    return WorkspaceBundlePreview(
      handle: preview,
      jobId: preview.jobId,
      sourceName: preview.sourceName,
      sourceDigest: preview.sourceDigest,
      revisionCount: preview.revisionCount,
    );
  }

  @override
  Future<WorkspaceBundlePreview> resumeImport(String jobId) async {
    final preview = await workflow.resume(jobId);
    return WorkspaceBundlePreview(
      handle: preview,
      jobId: preview.jobId,
      sourceName: preview.sourceName,
      sourceDigest: preview.sourceDigest,
      revisionCount: preview.revisionCount,
    );
  }

  BundleImportPreview _handle(WorkspaceBundlePreview preview) {
    final handle = preview.handle;
    if (handle is! BundleImportPreview || handle.jobId != preview.jobId) {
      throw StateError('完整同步预览不属于当前任务');
    }
    return handle;
  }

  @override
  Future<String> commitImport(WorkspaceBundlePreview preview) async {
    final receipt = await workflow.commit(_handle(preview));
    return '完整同步已一次提交：${receipt.resultCount} 条修订，generation ${receipt.version.generation}。';
  }

  @override
  Future<void> cancelImport(WorkspaceBundlePreview preview) =>
      workflow.cancel(_handle(preview));

  @override
  Future<String> exportBundle() async {
    final manifest = await workflow.pickAndExport();
    return '完整同步包已自验并写入所选文件：${manifest.revisionCount} 条修订 · ${manifest.revisionsDigest}';
  }
}
