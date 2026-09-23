import 'dart:io';

import '../app/workspace.dart';
import 'bundle_workflow.dart';
import 'native_bundle_workflow.dart';
import 'import_cancellation.dart';

final class NativeWorkspaceBundleActions implements WorkspaceBundleActions {
  const NativeWorkspaceBundleActions({
    required this.workflow,
    required this.exportDirectory,
  });

  final NativeBundleWorkflow workflow;
  final Directory exportDirectory;

  @override
  bool get importNeedsPath => true;

  @override
  Future<WorkspaceBundlePreview> prepareImport({
    String? sourcePath,
    ImportCancellation? cancellation,
  }) async {
    final preview = await workflow.preparePath(
      sourcePath ?? '',
      cancellation: cancellation,
    );
    return _preview(preview);
  }

  @override
  Future<WorkspaceBundlePreview> resumeImport(String jobId) async =>
      _preview(await workflow.resume(jobId));

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
    final result = await workflow.exportTo(exportDirectory);
    return '完整同步包已生成并自验：${result.path}\n${result.manifest.revisionCount} 条修订 · ${result.manifest.revisionsDigest}';
  }
}

WorkspaceBundlePreview _preview(BundleImportPreview preview) =>
    WorkspaceBundlePreview(
      handle: preview,
      jobId: preview.jobId,
      sourceName: preview.sourceName,
      sourceDigest: preview.sourceDigest,
      revisionCount: preview.revisionCount,
    );

BundleImportPreview _handle(WorkspaceBundlePreview preview) {
  final handle = preview.handle;
  if (handle is! BundleImportPreview || handle.jobId != preview.jobId) {
    throw StateError('完整同步预览不属于当前任务');
  }
  return handle;
}
