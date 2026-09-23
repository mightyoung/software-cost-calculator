import 'dart:io';
import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';
import '../tool/run_benchmarks.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('large-data-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'disk-backed 257-revision history commits one head and survives reopen',
    () async {
      final report = await runDeep(directory, depth: 257);
      expect(report['depth'], 257);
      expect(report['heads'], 1);
      expect(report['reopen_verified'], isTrue);
      expect(report['oracle_retained_revisions'], 1);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'unique long shared strings preserve every row using one-row oracle',
    () async {
      final report = await runStrings(directory, count: 257, length: 4096);
      expect(report['count'], 257);
      expect((report['profile'] as Map)['shared_strings'], 257);
      expect(report['oracle_retained_rows'], 1);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('32768-character cell fails the XLSX cell boundary', () async {
    await expectLater(
      runStrings(directory, count: 1, length: 32768),
      throwsA(
        isA<DomainFailure>().having((e) => e.code, 'code', 'INVALID_XLSX'),
      ),
    );
    final reopened = XlsxStaging(
      NativeDatabase(File('${directory.path}/strings.sqlite')),
    );
    try {
      await expectLater(reopened.profile(), throwsStateError);
      await expectLater(reopened.rowsPage(), throwsStateError);
    } finally {
      await reopened.close();
    }
  });

  test(
    '32767-character shared string preserves the permitted boundary',
    () async {
      final report = await runStrings(directory, count: 1, length: 32767);
      expect(report['text_length'], 32767);
    },
  );

  test('benchmark fixture itself refuses unbounded allocation', () async {
    await expectLater(
      runStrings(directory, count: 5000, length: 32767),
      throwsArgumentError,
    );
  });
}
