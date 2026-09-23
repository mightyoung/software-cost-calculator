import 'dart:io';
import 'dart:convert';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:test/test.dart';
import '../tool/full_chain_scale.dart' as scale;

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  test(
    'formal fixture produces exact cardinality and per-entity parent chains',
    () async {
      var count = 0;
      final heads = <String, String>{};
      await for (final revision in scale.fixture(6)) {
        expect(
          revision.parents,
          heads.containsKey(revision.entityId)
              ? [heads[revision.entityId]]
              : isEmpty,
        );
        heads[revision.entityId] = revision.revisionId;
        count++;
      }
      expect(count, 30);
      expect(heads.length, 8);
    },
  );
  test(
    'full-chain budget includes multiple databases and stays above query-only budget',
    () {
      expect(scale.requiredSpace(100000), greaterThan(8847360000));
      expect(
        scale.requiredSpace(100000),
        greaterThan(scale.requiredSpace(10000)),
      );
      expect(scale.requiredSpace(1), greaterThan(100 * 1024 * 1024));
    },
  );
  test(
    'formal backup restores, exports several verified volumes and survives reopen',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'full-chain-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final report = await scale.runFullChain(
        directory,
        count: 6,
        rowsPerVolume: 4,
      );
      expect(report['revision_count'], 30);
      expect(report['quotation_count'], 6);
      expect(report['volume_count'], greaterThan(5));
      expect(report['source_digest'], report['restored_digest']);
      expect(report['source_digest'], report['reopen_digest']);
      expect(
        await File('${directory.path}/export.bundle.zip').length(),
        greaterThan(0),
      );
      final hashes = await scale.sourceHashes();
      final evidence = <String, Object?>{
        'status': 'PASS',
        'kind': 'formal-full-chain',
        'count': 6,
        'source_sha256': hashes,
        'source_sha256_at_finish': hashes,
        'result': report,
      };
      final reportFile = File('${directory.path}/report.json');
      await reportFile.writeAsString(jsonEncode(evidence));
      final verified = await Process.run('python3', [
        'tool/verify_full_chain.py',
        directory.path,
      ]);
      expect(
        verified.exitCode,
        0,
        reason: '${verified.stdout}\n${verified.stderr}',
      );
      final authority = report['source_digest']! as Map<String, Object?>;
      authority['authority_sha256'] = '0' * 64;
      await reportFile.writeAsString(jsonEncode(evidence));
      final rejected = await Process.run('python3', [
        'tool/verify_full_chain.py',
        directory.path,
      ]);
      expect(rejected.exitCode, isNot(0));
      expect(rejected.stderr, contains('differs from SQLite'));
      expect(await File('${directory.path}/oracle.json').exists(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
