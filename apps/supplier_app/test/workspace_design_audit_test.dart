import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/settings/settings_page.dart';
import 'package:supplier_app/features/settings/ai_settings.dart';
import 'package:supplier_app/features/exchange/exchange_page.dart';
import 'package:supplier_app/features/exchange/passphrase.dart';
import 'package:supplier_app/features/trash/trash_page.dart';
import 'package:supplier_app/features/home/command_palette.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  testWidgets(
    'leaving AI settings while saving does not update disposed controls',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('ai-settings-design');
      final store = Store.open('${dir.path}/test.db', device: 'test');
      final state = AppState.test(store, dir);
      final write = Completer<void>();
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'write') await write.future;
        return null;
      });
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        );
        state.dispose();
        store.close();
        dir.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: SingleChildScrollView(child: AiSettings(state: state)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(2), 'test-key');
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      write.complete();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  for (final dark in [false, true]) {
    for (final page in [
      'settings',
      'exchange',
      'trash',
      'passphrase',
      'shortcuts',
      'palette',
    ]) {
      testWidgets('$page accessible compact layout dark=$dark', (tester) async {
        Tokens.dark = dark;
        addTearDown(() => Tokens.dark = false);
        final dir = Directory.systemTemp.createTempSync('workspace-design');
        final store = Store.open('${dir.path}/test.db', device: 'test');
        final state = AppState.test(store, dir);
        addTearDown(() {
          state.dispose();
          store.close();
          dir.deleteSync(recursive: true);
        });
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => null,
        );
        tester.view.physicalSize = Size(
          390,
          ['passphrase', 'shortcuts'].contains(page) ? 320 : 844,
        );
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.4),
                disableAnimations: true,
                viewInsets: page == 'palette'
                    ? const EdgeInsets.only(bottom: 400)
                    : EdgeInsets.zero,
              ),
              child: child!,
            ),
            home: Scaffold(
              body: switch (page) {
                'settings' => SettingsPage(state: state),
                'exchange' => ExchangePage(state: state),
                'trash' => TrashPage(state: state),
                'shortcuts' => Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showShortcutHelp(context),
                    child: const Text('打开'),
                  ),
                ),
                'palette' => Builder(
                  builder: (context) => TextButton(
                    onPressed: () => showCommandPalette(context, state, (_) {}),
                    child: const Text('打开'),
                  ),
                ),
                _ => Builder(
                  builder: (context) => TextButton(
                    onPressed: () => askPassphrase(
                      context,
                      title: '设置交换口令',
                      confirm: true,
                      message: '所有设备要设置同一个口令。口令只保存在本机的系统安全存储里，忘记后无法找回，但可以重新设置。',
                    ),
                    child: const Text('打开'),
                  ),
                ),
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (page == 'palette' || page == 'shortcuts') {
          await tester.tap(find.text('打开'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (page == 'palette') {
            expect(
              tester.getBottomLeft(find.text('↑↓ 选择 · Enter 打开 · Esc 关闭')).dy,
              lessThanOrEqualTo(444),
            );
          } else {
            await tester.tap(find.text('关闭'));
            await tester.pumpAndSettle();
            expect(find.byType(AlertDialog), findsNothing);
          }
        } else if (page == 'passphrase') {
          await tester.tap(find.text('打开'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('确定'));
          await tester.pumpAndSettle();
          expect(find.text('口令至少 8 位'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
        } else if (page != 'trash') {
          expect(tester.takeException(), isNull);
          for (var i = 0; i < 8; i++) {
            await tester.drag(
              find.byType(ListView).first,
              const Offset(0, -420),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
