import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_core/supplier_core.dart';

// Real async (not testWidgets): the work runs in another isolate.
void main() {
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

    File('${dir.path}/bad.siq').writeAsBytesSync([1, 2, 3]);
    final path = '${dir.path}/bad.siq';
    expect(
      await state.writeInBackground((s) => s.importFrom(path)),
      isNotNull,
      reason: 'errors come back as messages',
    );
  });
}
