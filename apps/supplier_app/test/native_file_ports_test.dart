import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/platform/native_file_ports.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('supplier-file-ports-');
  });
  tearDown(() async => directory.delete(recursive: true));
  PrivateFileOutput output() => PrivateFileOutput(
    temporary: File('${directory.path}/pending'),
    destination: File('${directory.path}/complete'),
  );

  test('range reads are exact, bounded and reject truncation', () async {
    final file = await File('${directory.path}/input')
        .writeAsBytes(List.generate(131072, (i) => i % 251));
    final source = NativeInputSource(file, displayName: '报价.xlsx');
    expect(await source.length(), 131072);
    var offset = 13;
    await for (final chunk in source.openRange(13, 100003)) {
      expect(chunk.length, lessThanOrEqualTo(65536));
      for (final value in chunk) {
        expect(value, offset++ % 251);
      }
    }
    expect(offset, 100003);
    await expectLater(source.openRange(-1, 1).drain<void>(), throwsRangeError);
    await expectLater(
      source.openRange(0, 131073).drain<void>(),
      throwsRangeError,
    );
    expect(await source.openRange(131072, 131072).isEmpty, isTrue);
    Future<void> truncateWhileReading() async {
      await for (final _ in source.openRange(0, 131072)) {
        final writer = await file.open(mode: FileMode.write);
        await writer.close();
      }
    }

    await expectLater(
      truncateWhileReading(),
      throwsA(isA<FileSystemException>()),
    );
  });

  test(
    'publish follows close; abort cannot remove a published output',
    () async {
      final target = output();
      await expectLater(target.publish(), throwsStateError);
      await target.write(
        Stream.fromIterable([
          [1, 2],
          [3],
        ]),
      );
      expect(await target.destination.exists(), isFalse);
      await target.publish();
      expect(await target.destination.readAsBytes(), [1, 2, 3]);
      expect(await target.temporary.exists(), isFalse);
      await expectLater(target.abort(), throwsStateError);
      await expectLater(target.publish(), throwsStateError);
    },
  );

  test(
    'stream failure removes partial output and preserves initiating error',
    () async {
      final target = output();
      final failure = StateError('lost source');
      Stream<List<int>> bytes() async* {
        yield [1];
        throw failure;
      }

      await expectLater(target.write(bytes()), throwsA(same(failure)));
      expect(await target.temporary.exists(), isFalse);
      await expectLater(target.publish(), throwsStateError);
      await target.abort();
    },
  );

  test('existing temporary and destination files are preserved', () async {
    final target = output();
    await target.temporary.writeAsString('existing');
    await expectLater(
      target.write(Stream.value([1])),
      throwsA(isA<FileSystemException>()),
    );
    await target.abort();
    expect(await target.temporary.readAsString(), 'existing');
    await target.temporary.delete();
    final next = output();
    await next.destination.writeAsString('keep');
    await next.write(Stream.value([2]));
    await expectLater(next.publish(), throwsA(isA<FileSystemException>()));
    await next.abort();
    expect(await next.destination.readAsString(), 'keep');
  });

  test(
    'two lock instances serialize; failures release the local queue',
    () async {
      final first = NativeApplicationWriteLock(
        File('${directory.path}/app.lock'),
      );
      final second = NativeApplicationWriteLock(
        File('${directory.path}/app.lock'),
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final failure = StateError('rollback');
      final pending = first.run(() async {
        entered.complete();
        await release.future;
        throw failure;
      });
      final observedFailure = expectLater(pending, throwsA(same(failure)));
      await entered.future;
      var secondEntered = false;
      final waiting = second.run(() async {
        secondEntered = true;
        return 42;
      });
      await Future<void>.delayed(Duration.zero);
      expect(secondEntered, isFalse);
      release.complete();
      await observedFailure;
      expect(await waiting, 42);
      expect(await first.run(() async => 'released'), 'released');
    },
  );

  test('recursive lock acquisition is rejected instead of hanging', () async {
    final first = NativeApplicationWriteLock(
      File('${directory.path}/app.lock'),
    );
    final second = NativeApplicationWriteLock(
      File('${directory.path}/app.lock'),
    );
    await expectLater(
      first.run(() => second.run(() async => 1)),
      throwsStateError,
    );
    expect(await first.run(() async => 2), 2);
  });

  test(
    'symlink aliases share the queue and recursive-acquisition guard',
    () async {
      final file = await File('${directory.path}/app.lock').create();
      final alias = Link('${directory.path}/alias.lock');
      await alias.create(file.path);
      final first = NativeApplicationWriteLock(file);
      final second = NativeApplicationWriteLock(File(alias.path));
      await expectLater(
        first.run(() => second.run(() async => 1)),
        throwsStateError,
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final pending = first.run(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      var aliasEntered = false;
      final waiting = second.run(() async {
        aliasEntered = true;
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(aliasEntered, isFalse);
      release.complete();
      await pending;
      await waiting;
      expect(aliasEntered, isTrue);
    },
    skip: Platform.isWindows
        ? 'Host symlink fixture needs creation privilege'
        : false,
  );

  test(
    'publication rejects concurrent abort and duplicate publication',
    () async {
      final target = output();
      await target.write(Stream.value([3]));
      final pending = target.publish();
      await expectLater(target.abort(), throwsStateError);
      await expectLater(target.publish(), throwsStateError);
      await pending;
      expect(await target.destination.readAsBytes(), [3]);
    },
  );
}
