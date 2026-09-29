import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/hub/hub_page.dart';
import 'package:supplier_app/features/hub/hub_publish.dart';
import 'package:supplier_app/features/hub/hub_settings.dart';
import 'package:supplier_core/supplier_core.dart';

// The publish-and-find flow runs against the real Rust hub when it has been
// built (cargo build in services/supplier_hub); skipped otherwise.
final _binary = File(
  '../../services/supplier_hub/target/debug/supplier-hub'
  '${Platform.isWindows ? '.exe' : ''}',
);

void main() {
  late Directory dir;
  late Store store;
  late AppState state;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('hub_ui');
    store = Store.open('${dir.path}/test.db', device: 'test');
    state = AppState.test(store, dir);
  });
  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  Widget app(Widget child) => MaterialApp(
    theme: buildTheme(),
    home: Scaffold(body: child),
  );

  testWidgets('without a hub the page explains how to connect', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      app(HubPage(state: state, onOpenSettings: () => opened = true)),
    );
    await tester.pump();
    expect(find.text('还没有连接公司资料中心'), findsOneWidget);
    await tester.tap(find.text('去设置'));
    expect(opened, isTrue);
  });

  testWidgets('plain http to another machine is flagged in settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(SingleChildScrollView(child: HubSettings(state: state))),
    );
    await tester.enterText(
      find.byType(TextField).first,
      'http://10.0.0.5:8080',
    );
    await tester.pump();
    expect(find.textContaining('明文'), findsOneWidget);
    await tester.enterText(
      find.byType(TextField).first,
      'http://127.0.0.1:8080',
    );
    await tester.pump();
    expect(find.textContaining('明文'), findsNothing);
  });

  testWidgets('publish a supplier, then find it in 公司资料', (tester) async {
    HttpOverrides.global = null; // real sockets to the local hub
    final hub = await tester.runAsync(() async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final config = File('${dir.path}/hub.toml')
        ..writeAsStringSync(
          'center_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"\n'
          'bind = "127.0.0.1:$port"\n'
          'database = "hub.sqlite"\n'
          '[sync]\nenabled = false\n',
        );
      final process = await Process.start(_binary.absolute.path, [
        'serve',
        config.path,
      ]);
      final base = Uri.parse('http://127.0.0.1:$port');
      for (var i = 0; ; i++) {
        try {
          await HubClient(base).status();
          break;
        } on HubException {
          if (i > 100) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      await state.saveHub(address: base.toString());
      return process;
    });
    addTearDown(() => hub!.kill());
    final supplier = store.save('supplier', {
      for (final f in Supplier.fields) f: null,
      'name': '华东泵业',
      'aliases': <String>[],
      'categories': <String>[],
    });

    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showHubPublish(context, state, type: 'supplier', id: supplier),
            child: const Text('publish'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('publish'));
    Future<void> settle(Finder until) async {
      for (var i = 0; i < 100 && until.evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }
      expect(until, findsWidgets);
    }

    await settle(find.textContaining('首次发布'));
    await tester.tap(find.text('发布'));
    await settle(find.textContaining('已发布到公司资料（第 1 版）'));

    await tester.pumpWidget(app(HubPage(state: state)));
    await tester.tap(find.text('供应商'));
    await settle(find.text('华东泵业'));
    expect(find.text('第 1 版'), findsOneWidget);
  }, skip: !_binary.existsSync());
}
