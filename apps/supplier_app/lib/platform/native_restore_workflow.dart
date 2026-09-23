import 'dart:io';

import 'package:supplier_core/supplier_core.dart';

import 'native_database_host.dart';
import 'native_file_ports.dart';
import 'restore_workflow.dart';

RestoreWorkflow<T> nativeRestoreWorkflow<T>({
  required NativeDatabaseHost host,
  required String sourcePath,
  required Future<void> Function() closeCurrent,
  required Future<T> Function() reopen,
}) => RestoreWorkflow<T>(
  prepare: () async {
    if (sourcePath.trim().isEmpty) {
      throw ArgumentError.value(sourcePath, 'sourcePath', '请选择备份文件');
    }
    final source = NativeInputSource(File(sourcePath), displayName: sourcePath);
    BackupSummary? summary;
    final candidateId = await host.prepareRestore(
      source,
      onPrepared: (value) => summary = value,
    );
    return RestorePreview(
      candidateId: candidateId,
      sourceName: source.displayName,
      summary: summary!,
    );
  },
  activate: host.activateRestore,
  closeCurrent: closeCurrent,
  reopen: reopen,
);
