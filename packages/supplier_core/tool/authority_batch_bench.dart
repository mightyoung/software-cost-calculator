import 'dart:convert';
import 'dart:io';
import 'package:supplier_core/supplier_core.dart';
import '../test/support/test_rig.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('authority-bench-');
  final rig = StorageTestRig(File('${directory.path}/data.sqlite'));
  try {
    final token = await rig.stage(count: 1000);
    final watch = Stopwatch()..start();
    final receipt =
        await CommitCoordinator(
          database: rig.database,
          writeLock: rig.lock,
          readActiveVersion: rig.active,
          pageSize: 500,
        ).commitStaged(
          jobId: token.jobId,
          expectedPreviewToken: token,
          confirmationEventId: 'event-job',
        );
    print(
      jsonEncode({
        'count': receipt.resultCount,
        'commit_ms': watch.elapsedMilliseconds,
        'generation': receipt.version.generation,
        'foreign_key_errors': (await rig.database.rows(
          'PRAGMA foreign_key_check',
        )).length,
      }),
    );
  } finally {
    await rig.database.close();
    await directory.delete(recursive: true);
  }
}
