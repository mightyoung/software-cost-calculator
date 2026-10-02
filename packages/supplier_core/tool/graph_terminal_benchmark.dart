/// Small graph-only comparison; not a release-scale benchmark.
library;

import 'dart:convert';
import 'dart:io';
import 'package:supplier_core/src/domain/revision_graph.dart';
import '../test/graph_terminal_test.dart' show TerminalTestWorkspace;
import '../test/support/test_rig.dart';
import 'full_chain_scale.dart' show fixture;

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('terminal-benchmark-');
  final rig = StorageTestRig(File('${dir.path}/db.sqlite'));
  final results = <String, int>{};
  try {
    await rig.database.createJob('job');
    await rig.database.transaction(() async {
      await for (final row in fixture(500)) {
        await rig.database.appendStaging('job', row);
      }
    });
    await rig.database.sealJob('job', 'decisions');
    for (var i = 0; i < 4; i++) {
      final enabled = i.isOdd;
      final key = '${enabled ? 'terminal' : 'baseline'}-$i';
      final work = TerminalTestWorkspace(
        rig.database,
        jobId: 'job',
        runId: key,
        enabled: enabled,
      );
      final timer = Stopwatch()..start();
      final result = await rig.database.transaction(
        () => RevisionGraphValidator().validate(work),
      );
      results[key] = timer.elapsedMilliseconds;
      if (result.revisions != 2500 ||
          result.entities != 502 ||
          result.heads != 502 ||
          result.anomalousEntities != 0) {
        throw StateError('Unexpected graph result');
      }
      await work.discardWork();
    }
    stdout.writeln(
      jsonEncode({
        'scope': 'small graph-only; shared host load',
        'ms': results,
      }),
    );
  } finally {
    await rig.database.close();
    await dir.delete(recursive: true);
  }
}
