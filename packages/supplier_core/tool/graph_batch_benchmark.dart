/// Small differential graph-only benchmark; not an A15 release measurement.
library;

import 'dart:convert';
import 'dart:io';
import 'package:supplier_core/src/data/graph_workspace.dart';
import 'package:supplier_core/src/domain/revision_graph.dart';
import '../test/graph_batch_test.dart' show ScalarWorkspace;
import '../test/support/test_rig.dart';
import 'full_chain_scale.dart' show fixture;

class FrontierOnlyWorkspace extends SqlGraphWorkspace {
  FrontierOnlyWorkspace(
    super.database, {
    required super.jobId,
    required super.runId,
  });
  @override
  Future<void> initializePage(List<GraphRevision> rows) => ScalarWorkspace(
    database,
    jobId: jobId,
    runId: runId,
  ).initializePage(rows);
}

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('graph-benchmark-');
  final rig = StorageTestRig(File('${directory.path}/source.sqlite'));
  final timings = <String, int>{};
  try {
    await rig.database.createJob('job');
    await rig.database.transaction(() async {
      await for (final revision in fixture(500)) {
        await rig.database.appendStaging('job', revision);
      }
    });
    await rig.database.sealJob('job', 'decisions');
    for (var iteration = 0; iteration < 6; iteration++) {
      final mode = ['scalar', 'frontier', 'page'][iteration % 3];
      final id = '$mode-$iteration';
      final work = switch (mode) {
        'scalar' => ScalarWorkspace(rig.database, jobId: 'job', runId: id),
        'frontier' => FrontierOnlyWorkspace(
          rig.database,
          jobId: 'job',
          runId: id,
        ),
        _ => SqlGraphWorkspace(rig.database, jobId: 'job', runId: id),
      };
      final watch = Stopwatch()..start();
      final result = await rig.database.transaction(
        () => RevisionGraphValidator().validate(work),
      );
      timings[id] = watch.elapsedMilliseconds;
      if (result.revisions != 2500 ||
          result.heads != 502 ||
          result.entities != 502 ||
          result.anomalousEntities != 0) {
        throw StateError('Unexpected graph result');
      }
      await work.discardWork();
    }
    stdout.writeln(
      jsonEncode({
        'count': 500,
        'revisions': 2500,
        'graph_validation_ms': timings,
        'scope': 'small native graph-only, shared host load',
      }),
    );
  } finally {
    await rig.database.close();
    await directory.delete(recursive: true);
  }
}
