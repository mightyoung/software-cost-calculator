import 'dart:io';

import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';

import 'business_import_workflow_adapter.dart';
import 'native_file_ports.dart';

final class NativeBusinessImport extends BusinessImportWorkflowAdapter {
  NativeBusinessImport({
    required super.exchange,
    required super.deviceId,
    required this.directory,
  });
  final Directory directory;
  @override
  bool get usesPath => true;
  @override
  Future<InputSource> selectSource(String path) async {
    if (path.trim().isEmpty || !File(path).isAbsolute) {
      throw ArgumentError('请输入 Excel 文件的完整路径');
    }
    final file = File(path);
    if (!await file.exists()) {
      throw const DomainFailure('source_missing', '文件不存在，请核对完整路径');
    }
    return NativeInputSource(file, displayName: path);
  }

  @override
  Future<XlsxStaging> openStaging(
    String jobId, {
    required bool existing,
  }) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,200}$').hasMatch(jobId)) {
      throw ArgumentError('无效任务编号');
    }
    await directory.create(recursive: true);
    final file = File('${directory.path}/$jobId.sqlite');
    if (existing && !await file.exists()) {
      throw const DomainFailure('import_staging_missing', '任务暂存已丢失，请重新选择文件');
    }
    if (!existing && await file.exists()) {
      throw const DomainFailure('import_staging_exists', '任务暂存已存在，拒绝覆盖');
    }
    return XlsxStaging(NativeDatabase(file));
  }
}
