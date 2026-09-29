import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_core/supplier_core.dart';

import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/platform/files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temp;
  late Store store;
  late AppState state;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('app-security-');
    store = Store.open('${temp.path}/db', device: 'test');
    state = AppState.test(store, temp);
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    state.dispose();
    store.close();
    temp.deleteSync(recursive: true);
  });

  test(
    'failed disk copy removes its partial directory; normal copy preserves bytes',
    () async {
      final scratch = Directory('${temp.path}/imports')..createSync();
      await expectLater(
        copyToTemp(
          Stream.fromIterable([
            [1, 2],
            [3, 4],
          ]),
          scratch,
          declaredLength: 2,
          maxBytes: 3,
        ),
        throwsFormatException,
      );
      expect(scratch.listSync(), isEmpty);
      final path = await copyToTemp(
        Stream.value([1, 2, 3]),
        scratch,
        declaredLength: 3,
        maxBytes: 3,
      );
      expect(File(path).readAsBytesSync(), [1, 2, 3]);
    },
  );

  test('LAN send refuses missing or unreadable key before exporting', () async {
    final node = await LanNode.start(
      id: 'test',
      name: 'test',
      inbox: Directory('${temp.path}/inbox'),
      onPush: (_) {},
      discoveryPort: 0,
      httpPort: 0,
    );
    state.lan = node;
    addTearDown(node.stop);
    final peer = LanPeer('peer', 'peer', '127.0.0.1', 1, DateTime.now());
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await state.pushTo(peer, {}), contains('设置交换口令'));
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'locked'),
    );
    expect(await state.pushTo(peer, {}), contains('安全存储'));
    expect(Directory('${temp.path}/tmp').listSync(), isEmpty);
  });

  test(
    'missing and present exchange keys remain distinct from storage failure',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      expect(await state.exchangePassphrase(), isNull);
      messenger.setMockMethodCallHandler(channel, (_) async => 'secret');
      expect(await state.exchangePassphrase(), 'secret');
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => throw PlatformException(code: 'locked'),
      );
      await expectLater(state.exchangePassphrase(), throwsFormatException);
      state.saveSetting('sync_dir', temp.path);
      await state.syncNow();
      expect(state.lastSyncError, contains('安全存储'));
      expect(temp.listSync().where((f) => f.path.endsWith('.siq')), isEmpty);
    },
  );

  test(
    'file stream rejects dishonest sizes and accepts exact bounded content',
    () async {
      expect(
        await boundedFileStream(
          Stream.value([1, 2, 3]),
          declaredLength: 3,
          maxBytes: 3,
        ).toList(),
        [
          [1, 2, 3],
        ],
      );
      await expectLater(
        boundedFileStream(
          Stream.value([1]),
          declaredLength: 4,
          maxBytes: 3,
        ).drain<void>(),
        throwsFormatException,
      );
      await expectLater(
        boundedFileStream(
          Stream.fromIterable([
            [1, 2],
            [3, 4],
          ]),
          declaredLength: 1,
          maxBytes: 3,
        ).drain<void>(),
        throwsFormatException,
      );
    },
  );
}
