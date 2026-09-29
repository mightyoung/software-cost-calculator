import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/features/exchange/import_flow.dart';
import 'package:supplier_core/supplier_core.dart';

Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 400 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory fixtures;
  late String encrypted;
  setUpAll(() async {
    fixtures = Directory.systemTemp.createTempSync('encrypted-flow-fixture-');
    final store = Store.open('${fixtures.path}/source.db', device: 'source');
    store.save('supplier', {
      for (final field in Supplier.fields) field: null,
      'name': 'Encrypted supplier',
      'aliases': <String>[],
      'categories': <String>[],
    });
    encrypted = '${fixtures.path}/source.siq';
    await store.exportEncryptedTo(encrypted, 'password');
    store.close();
  });
  tearDownAll(() => fixtures.deleteSync(recursive: true));

  for (final restore in [false, true]) {
    testWidgets(
      '${restore ? 'restore' : 'import'} reports oversized envelope without password retries',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('oversized-import-');
        final state = AppState.test(
          Store.open('${dir.path}/db', device: 'test'),
          dir,
        );
        addTearDown(() {
          state.store.close();
          dir.deleteSync(recursive: true);
          messenger.setMockMethodCallHandler(channel, null);
        });
        messenger.setMockMethodCallHandler(channel, (_) async => 'password');
        final file = File('${dir.path}/large.siq');
        final handle = file.openSync(mode: FileMode.write);
        handle.writeStringSync('SIQE1\n');
        handle.truncateSync(128 * 1024 * 1024 + 1);
        handle.closeSync();
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (c) {
                context = c;
                return const Scaffold();
              },
            ),
          ),
        );
        ({bool done, String? message})? result;
        final work =
            (restore
                    ? reviewAndRestore(context, state, file.path)
                    : reviewAndImport(context, state, file.path))
                .then((r) => result = r);
        await waitFor(tester, () => result != null);
        await work;
        expect(result?.done, isFalse);
        expect(find.textContaining('128 兆字节'), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(Directory('${dir.path}/tmp').existsSync(), isFalse);
      },
    );
    testWidgets(
      '${restore ? 'restore' : 'import'} permits explicit password when storage fails',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('manual-import-');
        final state = AppState.test(
          Store.open('${dir.path}/db', device: 'test'),
          dir,
        );
        addTearDown(() {
          state.store.close();
          dir.deleteSync(recursive: true);
          messenger.setMockMethodCallHandler(channel, null);
        });
        var writes = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'read') throw PlatformException(code: 'locked');
          writes++;
          return null;
        });
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (c) {
                context = c;
                return const Scaffold();
              },
            ),
          ),
        );
        ({bool done, String? message})? result;
        final work =
            (restore
                    ? reviewAndRestore(context, state, encrypted)
                    : reviewAndImport(context, state, encrypted))
                .then((r) => result = r);
        await tester.pumpAndSettle();
        expect(find.textContaining('仅用于本次导入，不保存'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'wrong password');
        await tester.tap(find.text('确定'));
        await waitFor(
          tester,
          () => find.text('口令不对，或文件已损坏。请重新输入。').evaluate().isNotEmpty,
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'password');
        await tester.tap(find.text('确定'));
        final preview = restore ? '整库恢复预览' : '导入预览';
        await waitFor(tester, () => find.text(preview).evaluate().isNotEmpty);
        await tester.pumpAndSettle();
        expect(writes, 0);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await work;
        expect(result?.done, isFalse);
        expect(Directory('${dir.path}/tmp').listSync(), isEmpty);
        expect(File(encrypted).existsSync(), isTrue);
      },
    );

    testWidgets(
      '${restore ? 'restore' : 'import'} cleans decrypted file after page disposal',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('disposed-import-');
        final state = AppState.test(
          Store.open('${dir.path}/db', device: 'test'),
          dir,
        );
        addTearDown(() {
          state.store.close();
          dir.deleteSync(recursive: true);
          messenger.setMockMethodCallHandler(channel, null);
        });
        final key = Completer<String>();
        messenger.setMockMethodCallHandler(channel, (_) => key.future);
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (c) {
                context = c;
                return const Scaffold();
              },
            ),
          ),
        );
        ({bool done, String? message})? result;
        final work =
            (restore
                    ? reviewAndRestore(context, state, encrypted)
                    : reviewAndImport(context, state, encrypted))
                .then((r) => result = r);
        await tester.pumpWidget(const SizedBox());
        expect(context.mounted, isFalse);
        key.complete('password');
        await waitFor(tester, () => result != null);
        await work;
        expect(result?.done, isFalse);
        expect(Directory('${dir.path}/tmp').listSync(), isEmpty);
        expect(File(encrypted).existsSync(), isTrue);
      },
    );
  }
}
