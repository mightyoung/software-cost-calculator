import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_core/supplier_core.dart';

Future<void> _delayedWrite(Store store) async {
  await Future<void>.delayed(const Duration(milliseconds: 80));
  store.save('supplier', {
    for (final f in Supplier.fields) f: null,
    'name': '在途导入',
    'aliases': <String>[],
    'categories': <String>[],
  });
}

// Real async (not testWidgets): the work runs in another isolate.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // These plain async integration tests use real local HTTP sockets.
  HttpOverrides.global = null;
  const storage = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => messenger.setMockMethodCallHandler(storage, (_) async => null));
  tearDown(() => messenger.setMockMethodCallHandler(storage, null));
  test('restore waits for an already running background write', () async {
    final dir = Directory.systemTemp.createTempSync('restore_pending_write');
    addTearDown(() => dir.deleteSync(recursive: true));
    final state = AppState.test(
      Store.open('${dir.path}/current.db', device: '甲'),
      dir,
    );
    addTearDown(state.store.close);
    final pending = state.writeInBackground(_delayedWrite);
    await state.suspendSyncForRestore();
    expect(await pending, isNull);
    expect(
      state.store.db.select('SELECT count(*) AS n FROM supplier').first['n'],
      1,
    );
  });

  test('shared-folder sync and imports run in a background isolate', () async {
    final dir = Directory.systemTemp.createTempSync('background_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final other = Store.open('${dir.path}/other.db', device: '乙');
    final id = other.save('supplier', {
      for (final f in Supplier.fields) f: null,
      'name': '甲泵业',
      'aliases': <String>[],
      'categories': <String>[],
    });
    final shared = Directory('${dir.path}/shared')..createSync();
    other.exportTo('${shared.path}/乙.siq');
    other.close();

    final state =
        AppState.test(Store.open('${dir.path}/t.db', device: '甲'), dir)
          ..saveSetting('sync_dir', shared.path)
          ..saveSetting('device_id', '12345678-aaaa-4bbb-8ccc-1234567890ab');
    await Future.wait([state.syncNow(), state.syncNow()]); // second joins
    expect(state.lastSyncError, isNull);
    expect(state.lastSync!.imported, ['乙.siq']);
    expect(state.store.get('supplier', id), isNotNull);
    expect(File('${shared.path}/${state.syncFileName}').existsSync(), isTrue);

    await state.suspendSyncForRestore();
    expect(state.syncDir, isNull);
    expect(state.setting('sync_seen'), isNull);
    final changed = Store.open('${dir.path}/other.db', device: '乙');
    changed.save('supplier', {
      for (final f in Supplier.fields) f: null,
      'name': '暂停后新增',
      'aliases': <String>[],
      'categories': <String>[],
    });
    changed.exportTo('${shared.path}/updated.siq');
    changed.close();
    await state.syncNow();
    expect(
      state.store.db.select('SELECT count(*) AS n FROM supplier').first['n'],
      1,
    );

    File('${dir.path}/bad.siq').writeAsBytesSync([1, 2, 3]);
    final path = '${dir.path}/bad.siq';
    expect(
      await state.writeInBackground((s) => s.importFrom(path)),
      isNotNull,
      reason: 'errors come back as messages',
    );
  });

  test('pushes a chosen project to a nearby device and receives one', () async {
    messenger.setMockMethodCallHandler(storage, (_) async => 'shared password');
    final dir = Directory.systemTemp.createTempSync('lan_app_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = Store.open('${dir.path}/a.db', device: '甲');
    final pro = store.save('project', {
      for (final f in Project.fields) f: null,
      'code': 'P-1',
      'name': '泵房改造',
      'status': 'active',
      'type': 'market',
      'level': 'A',
      'currency': 'CNY',
      'tax_mode': 'included',
      'markup_rate': '0',
    });
    final state = AppState.test(store, dir);
    await state.setLanVisible(true);
    addTearDown(() => state.setLanVisible(false));
    expect(state.lanError, isNull);

    final got = <LanPush>[];
    final other = await LanNode.start(
      id: 'other',
      name: '仓库平板',
      inbox: Directory('${dir.path}/other'),
      onPush: got.add,
      discoveryPort: 0,
      httpPort: 0,
    );
    addTearDown(other.stop);
    final peer = await state.lan!.probe('127.0.0.1', port: other.httpPort);
    expect(
      await state.pushTo(peer, {
        'project': [pro],
      }),
      isNull,
    );
    final b = Store.open('${dir.path}/b.db', device: '乙');
    addTearDown(b.close);
    expect(isEncryptedExchange(got.single.path), isTrue);
    b.importFrom(
      await decryptExchange(got.single.path, 'shared password', dir),
    );
    expect(b.get('project', pro)!.data['name'], '泵房改造');

    // The other way: a push lands in this device's inbox, nothing imported.
    final me = await other.probe('127.0.0.1', port: state.lan!.httpPort);
    await other.push(me, got.single.path);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(state.incoming.single.fromName, '仓库平板');
    state.dismissPush(state.incoming.single);
    expect(state.incoming, isEmpty);
  });
}
