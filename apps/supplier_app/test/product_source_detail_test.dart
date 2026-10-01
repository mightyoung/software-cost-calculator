import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
// Reuse the native channel boundary without showing an operating-system dialog.
// ignore: depend_on_referenced_packages
import 'package:file_picker_darwin/file_picker_darwin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/features/catalog/detail_panel.dart';
import 'package:supplier_app/features/quotes/quote_extras.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Store store;
  late AppState state;
  late String attachmentId, productId;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('product_source_detail');
    store = Store.open('${dir.path}/library.db', device: 'test');
    attachmentId = store.addAttachment(
      '采购来源.json',
      utf8.encode('{"source":"https://example.com/product"}'),
      mime: 'application/json',
    );
    productId = store.save('product', {
      for (final field in Product.fields) field: null,
      'name': '研究物料',
      'unit': '台',
      'source_attachment_ids': [attachmentId],
    });
    store.close();
    store = Store.open('${dir.path}/library.db', device: 'test');
    state = AppState.test(store, dir);
  });
  tearDown(() {
    state.dispose();
    store.close();
    dir.deleteSync(recursive: true);
  });

  testWidgets(
    'reopened product without quotations exposes readonly source and saveBytes action',
    (tester) async {
      final previousPicker = FilePickerPlatform.instance;
      FilePickerDarwin.registerWith();
      const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
      final messenger = tester.binding.defaultBinaryMessenger;
      var saveCalls = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'save');
        expect(call.arguments['fileName'], '采购来源.json');
        saveCalls++;
        return null; // User-cancelled save; no filesystem or OS dialog action.
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        FilePickerPlatform.instance = previousPicker;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CatalogDetail(state: state, type: 'product', id: productId),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(store.db.select('SELECT * FROM quotation'), isEmpty);
      expect(find.text('采购来源'), findsOneWidget);
      expect(find.text('网页资料尚待核实；可另存原始来源及字段证据查看。'), findsOneWidget);
      expect(find.text('采购来源.json'), findsOneWidget);
      final attachments = find.byType(AttachmentsField);
      expect(tester.widget<AttachmentsField>(attachments).readOnly, isTrue);
      expect(
        find.descendant(of: attachments, matching: find.text('添加报价单、截图等')),
        findsNothing,
      );
      expect(find.byTooltip('从这条报价移除（原件仍保留在本机）'), findsNothing);
      await tester.ensureVisible(find.byTooltip('另存一份查看'));
      await tester.tap(find.byTooltip('另存一份查看'));
      await tester.pumpAndSettle();
      expect(saveCalls, 1);
      expect(tester.takeException(), isNull);
      expect(store.get('product', productId)!.data['source_attachment_ids'], [
        attachmentId,
      ]);
    },
  );

  testWidgets('ordinary quotation attachments retain add and remove controls', (
    tester,
  ) async {
    List<String>? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AttachmentsField(
            state: state,
            ids: [attachmentId],
            onChanged: (ids) => changed = ids,
          ),
        ),
      ),
    );
    expect(find.text('添加报价单、截图等'), findsOneWidget);
    expect(find.byTooltip('另存一份查看'), findsOneWidget);
    expect(find.byTooltip('从这条报价移除（原件仍保留在本机）'), findsOneWidget);
    await tester.tap(find.byTooltip('从这条报价移除（原件仍保留在本机）'));
    await tester.pump();
    expect(changed, isEmpty);
    expect(store.attachment(attachmentId), isNotNull);
  });
}
