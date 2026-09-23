import 'package:supplier_core/supplier_core.dart';

import 'web_database_host.dart';
import 'web_file_ports.dart';
import 'restore_workflow.dart';

RestoreWorkflow<T> webRestoreWorkflow<T>({
  required WebDatabaseHost host,
  required Future<void> Function() closeCurrent,
  required Future<T> Function() reopen,
}) => RestoreWorkflow<T>(
  prepare: () async {
    // Call prepare directly from the user gesture to acquire the browser handle.
    final source = await WebInputSource.pick();
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
