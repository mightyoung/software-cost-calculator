import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:test/test.dart';
import '../tool/a17_concurrency.dart' as a17;

void main() {
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  test(
    'A17 first/middle/last volume edits with completion, cancel and SIGKILL',
    () async {
      final dir = await Directory.systemTemp.createTemp('supplier-a17-');
      addTearDown(() => dir.delete(recursive: true));
      final report = await a17.runMatrix(dir);
      expect(report['status'], 'PASS');
      final cases = report['cases']! as List;
      expect(cases, hasLength(9));
      for (final entry in cases.cast<Map<String, Object?>>()) {
        expect(entry['status'], 'PASS');
        expect(entry['concurrent_edit_survives_reopen'], isTrue);
        if (entry['action'] == 'cancel') {
          expect(
            (entry['cancellation'] as Map)['observed_by_exporter_checkpoint'],
            isTrue,
          );
        }
        final observation = entry['observation'] as Map;
        expect(
          observation['active_generation'],
          greaterThan(observation['frozen_generation'] as int),
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'A17 cancellation assertion fails if exporter checkpoint is omitted',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'supplier-a17-no-checkpoint-',
      );
      addTearDown(() => dir.delete(recursive: true));
      await expectLater(
        a17.child(dir, 5, 'cancel', enableCheckpoint: false),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Unexpected snapshot contents',
          ),
        ),
      );
      expect(await File('${dir.path}/published.zip').exists(), isTrue);
      expect(
        await File('${dir.path}/cancel-checkpoint.json').exists(),
        isFalse,
      );
    },
  );
}
