import 'package:drift/wasm.dart';
import 'package:supplier_core/supplier_core.dart';

import 'business_import_workflow_adapter.dart';
import 'web_file_ports.dart';

final class WebBusinessImport extends BusinessImportWorkflowAdapter {
  WebBusinessImport({
    required super.exchange,
    required super.deviceId,
    required this.namespace,
  });
  final String namespace;
  static Future<WasmProbeResult>? _probe;
  @override
  bool get usesPath => false;
  @override
  Future<InputSource> selectSource(String path) => WebInputSource.pick();
  @override
  Future<XlsxStaging> openStaging(
    String jobId, {
    required bool existing,
  }) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,200}$').hasMatch(jobId)) {
      throw ArgumentError('无效任务编号');
    }
    final probe = await (_probe ??= WasmDatabase.probe(
      sqlite3Uri: Uri.base.resolve('sqlite3.wasm'),
      driftWorkerUri: Uri.base.resolve('drift_worker.js'),
    ));
    final stores =
        probe.availableStorages
            .where((value) => value.storageApi == WebStorageApi.opfs)
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    if (stores.isEmpty) {
      throw const DomainFailure(
        'persistent_storage_unavailable',
        '导入预览需要可恢复的 OPFS 暂存',
      );
    }
    return XlsxStaging(
      await probe.open(stores.first, '$namespace-business-$jobId'),
    );
  }
}
