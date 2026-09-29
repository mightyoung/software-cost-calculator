import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/exchange/import_flow.dart';
import 'package:supplier_app/features/exchange/lan_push_page.dart';
import 'package:supplier_core/supplier_core.dart';

// Only discovery is needed: no sockets or network delivery in this UI test.
class _DiscoveredNode implements LanNode {
  _DiscoveredNode(this.peers);
  @override
  final List<LanPeer> peers;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'long LAN device remains selectable on short phone, dark=$dark',
      (tester) async {
        Tokens.dark = dark;
        addTearDown(() => Tokens.dark = false);
        final dir = Directory.systemTemp.createTempSync('lan_design');
        final store = Store.open('${dir.path}/test.db', device: '测试');
        addTearDown(() {
          store.close();
          dir.deleteSync(recursive: true);
        });
        final state = AppState.test(store, dir);
        final supplier = store.save('supplier', {
          for (final f in Supplier.fields) f: null,
          'name': '供应商',
          'aliases': <String>[],
          'categories': <String>[],
        });
        final peer = LanPeer(
          'remote',
          '工程采购中心的长名称工作站',
          '192.168.100.200',
          58764,
          DateTime.now(),
        );
        state.lan = _DiscoveredNode([peer]);
        tester.view.physicalSize = const Size(390, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.4),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: LanPushPage(
              state: state,
              chosen: {
                'supplier': {supplier},
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byType(DropdownButton<LanPeer>));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining(peer.name).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          tester
              .widget<DropdownButton<LanPeer>>(
                find.byType(DropdownButton<LanPeer>),
              )
              .value,
          same(peer),
        );
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '推送'))
              .onPressed,
          isNotNull,
        );
        expect(
          find.widgetWithText(FilledButton, '推送').hitTestable(),
          findsOneWidget,
        );
      },
    );

    for (final restore in [false, true]) {
      testWidgets(
        '${restore ? 'restore' : 'exchange'} preview scrolls before confirming, dark=$dark',
        (tester) async {
          Tokens.dark = dark;
          addTearDown(() => Tokens.dark = false);
          final dir = Directory.systemTemp.createTempSync('exchange_design');
          final source = Store.open('${dir.path}/source.db', device: '来源');
          source.save('supplier', {
            for (final f in Supplier.fields) f: null,
            'name': '来源供应商',
            'aliases': <String>[],
            'categories': <String>[],
          });
          final snapshot = '${dir.path}/snapshot.siq';
          source.exportTo(snapshot);
          source.close();
          final store = Store.open('${dir.path}/current.db', device: '本机');
          final state = AppState.test(store, dir);
          addTearDown(() {
            store.close();
            dir.deleteSync(recursive: true);
          });
          tester.view.physicalSize = const Size(390, 440);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          ({bool done, String? message})? result;
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(1.4),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    child: const Text('预览'),
                    onPressed: () async {
                      result = restore
                          ? await reviewAndRestore(context, state, snapshot)
                          : await reviewAndImport(context, state, snapshot);
                    },
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('预览'));
          for (
            var i = 0;
            i < 60 && find.byType(AlertDialog).evaluate().isEmpty;
            i++
          ) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 50)),
            );
            await tester.pump();
          }
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(tester.takeException(), isNull);
          expect(
            tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
            isTrue,
          );
          await tester.drag(
            find.byType(SingleChildScrollView).last,
            const Offset(0, -240),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('取消').last);
          await tester.pumpAndSettle();
          expect(result?.done, isFalse);
          expect(
            store.searchByName('supplier', ''),
            isEmpty,
            reason: '取消预览不写入资料',
          );
        },
      );
    }
  }
}
