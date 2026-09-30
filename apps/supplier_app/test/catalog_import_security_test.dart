import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
// Exercise the registered picker implementation at its native channel boundary.
// ignore: depend_on_referenced_packages
import 'package:file_picker_darwin/file_picker_darwin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/features/catalog/catalog_import.dart';
import 'package:supplier_core/supplier_core.dart';

// Minimal XLSX: name header, one supplier, then 33 references to a shared
// 32767-space string. Embedding the ZIP keeps the UI test dependency-free.
Uint8List amplifiedSupplierWorkbook() => base64Decode(
  'UEsDBBQAAAAIAAELQV0R2lpfPAAAAEwAAAAPAAAAeGwvd29ya2Jvb2sueG1ssynPL8pOys/PVqjI'
  'zckrtiqyVSpSsrMpzkhNLSmG0gp5ibmptkrBSgpFVpkptkrFSvp2NvowJfowE+wAUEsDBBQAAAAI'
  'AAELQV3V3Bo0OwAAAE8AAAAaAAAAeGwvX3JlbHMvd29ya2Jvb2sueG1sLnJlbHOzCUrNSSzJzM8r'
  'zsgsKLazQeYqeKbYKhUrKYQkFqWnltgqlecXZRdnpKaWFOsX61Xk5ijp29noo+oHAFBLAwQUAAAA'
  'CAABC0FdOvrrYUUAAAAagAAAFAAAAHhsL3NoYXJlZFN0cmluZ3MueG1s7cQxDQAxEAMwKs+gBKLw'
  '6XzHX9XzsAdnZpu5zfYDAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHK2OXP/ZvsAUEsD'
  'BBQAAAAIAAELQV1ZEy1RywAAAMYFAAATAAAAeGwvd29ya3NoZWV0cy9zLnhtbI3UzQnCMBiH8VWk'
  'C6TvGz8hBhQ3cIJSChalhTa0Uwhu4VUQR1LXsPZiL5XnEALh+Z9+ENeW1bE+ZFnwrr92SUi8q8rW'
  'u3RSraONRJOwjvLilBfZPlSRd3ntXfDPy/l9vTnTDc33xaTd6XeDsY6MX/fH/+XW9su6WzQ+dqYZ'
  'yaYsm7FszrIFy5YsW7FMYtgJ7BR2UEIghUALgRgCNQRyCPRQ6KHQQ6GHQg+FHgo9FHoo9FDoodDD'
  'Qg8LPSz0sNDDQg/7z8MM/mjz+7o/UEsBAhQDFAAAAAgAAQtBXRHaWl88AAAATAAAAA8AAAAAAAAA'
  'AAAAAIABAAAAAHhsL3dvcmtib29rLnhtbFBLAQIUAxQAAAAIAAELQV3V3Bo0OwAAAE8AAAAaAAAA'
  'AAAAAAAAAACAAWkAAAB4bC9fcmVscy93b3JrYm9vay54bWwucmVsc1BLAQIUAxQAAAAIAAELQV06'
  '+uthRQAAABqAAAAUAAAAAAAAAAAAAACAAdwAAAB4bC9zaGFyZWRTdHJpbmdzLnhtbFBLAQIUAxQA'
  'AAAIAAELQV1ZEy1RywAAAMYFAAATAAAAAAAAAAAAAACAAVMBAAB4bC93b3Jrc2hlZXRzL3MueG1s'
  'UEsFBgAAAAAEAAQACAEAAE8CAAAAAA==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory dir;
  late Store store;
  late AppState state;
  late FilePickerPlatform previousPicker;
  late File selectedFile;
  var pickerCalls = 0;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('catalog_import_security');
    store = Store.open('${dir.path}/library.db', device: '测试机');
    state = AppState.test(store, dir);
    previousPicker = FilePickerPlatform.instance;
    FilePickerDarwin.registerWith();
    pickerCalls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'custom');
      expect(call.arguments['allowedExtensions'], ['xlsx']);
      expect(call.arguments['allowMultipleSelection'], isFalse);
      pickerCalls++;
      return [
        {
          'path': selectedFile.path,
          'name': 'suppliers.xlsx',
          'size': selectedFile.lengthSync(),
        },
      ];
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    FilePickerPlatform.instance = previousPicker;
    state.dispose();
    store.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> selectWorkbook(WidgetTester tester, Uint8List bytes) async {
    selectedFile = File('${dir.path}/suppliers.xlsx')..writeAsBytesSync(bytes);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => importCatalogList(context, state, 'supplier'),
              child: const Text('导入'),
            ),
          ),
        ),
      ),
    );
    // Real disk reads must complete outside the widget test's fake async zone.
    await tester.runAsync(() async {
      await tester.tap(find.text('导入'));
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
        if (find.byType(AlertDialog).evaluate().isNotEmpty ||
            find.byType(SnackBar).evaluate().isNotEmpty) {
          break;
        }
      }
    });
    await tester.pumpAndSettle();
    expect(pickerCalls, 1);
  }

  testWidgets(
    'supplier shared-string amplification shows error before preview',
    (tester) async {
      final bytes = amplifiedSupplierWorkbook();
      expect(bytes.length, lessThan(10000));
      await selectWorkbook(tester, bytes);

      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('确认导入'), findsNothing);
      expect(find.text('无法读取 suppliers.xlsx：工作簿文本过大，请拆分后导入'), findsOneWidget);
      expect(store.searchByName('supplier', ''), isEmpty);
      expect(store.db.select('SELECT * FROM change_log'), isEmpty);
    },
  );

  testWidgets('normal supplier file previews before confirmed import', (
    tester,
  ) async {
    await selectWorkbook(
      tester,
      writeXlsx([
        SheetData('供应商', [
          ['供应商名称', '联系人', '电话'],
          ['甲泵业', '张三', '13800000000'],
          ['乙机电', '李四', '13900000000'],
        ]),
      ]),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('导入供应商：suppliers.xlsx'), findsOneWidget);
    expect(
      find.text('新建 2 家 · 已有 0 家（只补充新的联系人）· 带联系方式 2 行 · 有问题 0 行'),
      findsOneWidget,
    );
    expect(store.searchByName('supplier', ''), isEmpty);
    await tester.tap(find.text('确认导入'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('新建供应商 2，联系人 2'), findsOneWidget);
    final suppliers = store.searchByName('supplier', '');
    expect(suppliers, hasLength(2));
    expect(
      suppliers.expand((supplier) => store.contactsOf(supplier.id)),
      hasLength(2),
    );
  });
}
