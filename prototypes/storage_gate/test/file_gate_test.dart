import 'dart:io';
import 'package:storage_gate/file_gate.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  setUp(
    () async => directory = await Directory.systemTemp.createTemp('file-gate-'),
  );
  tearDown(() async => directory.delete(recursive: true));
  test('8 MiB source: exact bounded ranges and invalid boundaries', () async {
    final file = File('${directory.path}/input');
    final block = List<int>.generate(65536, (i) => i % 251);
    final handle = await file.open(mode: FileMode.write);
    for (var i = 0; i < 128; i++) {
      await handle.writeFrom(block);
    }
    await handle.close();
    final source = FileRangeSource(file);
    var count = 0;
    await for (final chunk in source.openRange(65530, 150000)) {
      expect(chunk.length, lessThanOrEqualTo(65536));
      for (final byte in chunk) {
        expect(byte, ((65530 + count) % 65536) % 251);
        count++;
      }
    }
    expect(count, 84470);
    expect(await source.openRange(8388608, 8388608).isEmpty, isTrue);
    await expectLater(source.openRange(-1, 2).drain<void>(), throwsRangeError);
    await expectLater(
      source.openRange(0, 8388609).drain<void>(),
      throwsRangeError,
    );
  });
  test(
    'publication requires a completed close and preserves all bytes',
    () async {
      final output = FileOutputExperiment(File('${directory.path}/pending'));
      await expectLater(
        output.publish('${directory.path}/done'),
        throwsStateError,
      );
      await output.write(
        Stream.fromIterable([
          [1, 2],
          [3],
        ]),
      );
      final file = await output.publish('${directory.path}/done');
      expect(await file.readAsBytes(), [1, 2, 3]);
      await expectLater(output.abort(), throwsStateError);
    },
  );
  test(
    'source failure discards partial output and prevents publication',
    () async {
      final temporary = File('${directory.path}/pending');
      final output = FileOutputExperiment(temporary);
      Stream<List<int>> failing() async* {
        yield [1, 2, 3];
        throw const FileSystemException('Simulated lost source handle');
      }

      await expectLater(
        output.write(failing()),
        throwsA(isA<FileSystemException>()),
      );
      expect(await temporary.exists(), isFalse);
      await expectLater(
        output.publish('${directory.path}/done'),
        throwsStateError,
      );
      await output.abort();
    },
  );
  test('existing files survive failed reservation and publication', () async {
    final existing = await File('${directory.path}/done').writeAsString('keep');
    final collision = FileOutputExperiment(existing);
    await expectLater(
      collision.write(Stream.value([9])),
      throwsA(isA<FileSystemException>()),
    );
    await collision.abort();
    expect(await existing.readAsString(), 'keep');
    final output = FileOutputExperiment(File('${directory.path}/pending'));
    await output.write(Stream.value([9]));
    await expectLater(
      output.publish(existing.path),
      throwsA(isA<FileSystemException>()),
    );
    expect(await existing.readAsString(), 'keep');
    await output.abort();
    expect(await output.temporary.exists(), isFalse);
  });
  test('truncation during range read fails instead of short success', () async {
    final file = await File(
      '${directory.path}/input',
    ).writeAsBytes(List.filled(131072, 7));
    var chunks = 0;
    Future<void> read() async {
      await for (final _ in FileRangeSource(file).openRange(0, 131072)) {
        chunks++;
        final writer = await file.open(mode: FileMode.write);
        await writer.close();
      }
    }

    await expectLater(read(), throwsA(isA<FileSystemException>()));
    expect(chunks, 1);
  });
  test(
    'cleanup permission failure preserves source failure and allows retry',
    () async {
      final temporary = File('${directory.path}/pending');
      final output = FileOutputExperiment(temporary);
      final primary = StateError('source failed');
      Stream<List<int>> failing() async* {
        yield [1];
        final chmod = await Process.run('chmod', ['500', directory.path]);
        expect(chmod.exitCode, 0);
        throw primary;
      }

      try {
        await expectLater(
          output.write(failing()),
          throwsA(
            isA<FileWriteFailure>()
                .having((e) => e.primary, 'primary', same(primary))
                .having(
                  (e) => e.cleanup.single.error,
                  'cleanup',
                  isA<FileSystemException>(),
                ),
          ),
        );
        await expectLater(
          output.publish('${directory.path}/done'),
          throwsStateError,
        );
      } finally {
        await Process.run('chmod', ['700', directory.path]);
      }
      await output.abort();
      expect(await temporary.exists(), isFalse);
    },
  );
}
