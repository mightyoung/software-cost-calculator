import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:test/test.dart';
import '../tool/full_chain_scale.dart' as scale;
import '../tool/resume_full_chain.dart' as resume;

void main() {
  late Directory root;
  late Directory input;
  late String authority;
  setUpAll(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    root = await Directory.systemTemp.createTemp('resume-chain-test-');
    input = await Directory('${root.path}/input').create();
    final fixture = await scale.runFullChain(input, count: 2, rowsPerVolume: 2);
    authority = (fixture['source_digest'] as Map)['authority_sha256'] as String;
  });
  tearDownAll(() => root.delete(recursive: true));

  test(
    'resumes from immutable checkpoint and reports separate measurements',
    () async {
      final out = Directory('${root.path}/success');
      final report = await resume.resumeFullChain(
        input,
        out,
        count: 2,
        expectedAuthority: authority,
        rowsPerVolume: 2,
      );
      expect(report['status'], 'PASS', reason: '${report['error']}');
      expect(report['kind'], 'formal-full-chain-resumed');
      expect(report['separate_process'], isTrue);
      expect(
        report['input_file_sha256'],
        report['input_file_sha256_at_finish'],
      );
      final result = report['result'] as Map;
      expect(result['source_digest'], result['restored_digest']);
      expect(result['source_digest'], result['reopen_digest']);
      expect(
        report['missing_original_phase_timings'],
        contains('formal_fixture_commit'),
      );
      expect(
        (report['resumed_timings_ms'] as Map).containsKey(
          'formal_fixture_commit',
        ),
        isFalse,
      );
      expect(
        jsonDecode(
          await File('${out.path}/report.json').readAsString(),
        )['status'],
        'PASS',
      );
      await expectLater(
        resume.resumeFullChain(
          input,
          out,
          count: 2,
          expectedAuthority: authority,
        ),
        throwsArgumentError,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('wrong checkpoint authority fails before restoring', () async {
    final out = Directory('${root.path}/bad-authority');
    final report = await resume.resumeFullChain(
      input,
      out,
      count: 2,
      expectedAuthority: '0' * 64,
    );
    expect(report['status'], 'FAIL');
    expect(report['error'], contains('checkpoint digest'));
    expect(await File('${out.path}/restored.sqlite').exists(), isFalse);
  });

  test('capacity admission leaves an explicit blocked report', () async {
    final out = Directory('${root.path}/no-space');
    final report = await resume.resumeFullChain(
      input,
      out,
      count: 2,
      expectedAuthority: authority,
      freeSpace: (_) async => 0,
    );
    expect(report['status'], 'BLOCKED');
    expect(await File('${out.path}/restored.sqlite').exists(), isFalse);
    expect(
      jsonDecode(
        await File('${out.path}/report.json').readAsString(),
      )['status'],
      'BLOCKED',
    );
  });

  test(
    'journal-bearing source is refused without deleting its evidence',
    () async {
      final journal = File('${input.path}/source.sqlite-journal');
      await journal.writeAsString('interrupted');
      try {
        await expectLater(
          resume.resumeFullChain(
            input,
            Directory('${root.path}/journal'),
            count: 2,
            expectedAuthority: authority,
          ),
          throwsStateError,
        );
        expect(await journal.readAsString(), 'interrupted');
      } finally {
        await journal.delete();
      }
    },
  );
}
