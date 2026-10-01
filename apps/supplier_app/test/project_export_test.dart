import 'dart:io';

// Exercise the registered Android picker at its native channel boundary.
// ignore: depend_on_referenced_packages
import 'package:android_file_picker/android_file_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/projects/project_detail.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('miguelruivo.flutter.plugins.filepicker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory dir;
  late Store store;
  late AppState state;
  late String project;
  late FilePickerPlatform previousPicker;
  final calls = <MethodCall>[];
  String? savedUri;
  PlatformException? saveError;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('project_export');
    store = Store.open('${dir.path}/library.db', device: '测试机');
    state = AppState.test(store, dir);
    project = store.save('project', {
      for (final f in Project.fields) f: null,
      'code': 'P-1',
      'name': '一期',
      'status': 'active',
      'currency': 'CNY',
      'tax_mode': 'included',
      'markup_rate': '0',
    });
    previousPicker = FilePickerPlatform.instance;
    FilePickerAndroid.registerWith();
    calls.clear();
    savedUri = 'content://com.android.externalstorage.documents/document/quote';
    saveError = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (saveError case final error?) throw error;
      return savedUri;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    FilePickerPlatform.instance = previousPicker;
    state.dispose();
    store.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> exportQuote(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: ProjectDetail(state: state, projectId: project, compact: true),
        ),
      ),
    );
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出项目报价单（给客户）'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    expect(calls.single.method, 'save');
    final args = calls.single.arguments as Map;
    expect(args['fileName'], startsWith('项目报价单-一期-'));
    expect(args['fileName'], endsWith('.xlsx'));
    final book = readXlsx(args['bytes'] as Uint8List);
    expect(book.sheets.single.name, '报价单');
    expect(book.sheets.single.rows.first.first.text(), '项目报价单');
    expect(book.sheets.single.rows[1][1].text(), '一期（P-1）');
  }

  testWidgets('Android quote export reports missing document picker', (
    tester,
  ) async {
    saveError = PlatformException(code: 'explorer_not_found');
    await exportQuote(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('导出失败：无法打开系统文件管理器，请确认已启用文件管理器后重试'), findsOneWidget);
    expect(find.text('已导出项目报价单'), findsNothing);
  });

  testWidgets('Android quote export sends workbook and reports success', (
    tester,
  ) async {
    await exportQuote(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('已导出项目报价单'), findsOneWidget);
  });

  testWidgets('Android quote export reports other save failures', (
    tester,
  ) async {
    saveError = PlatformException(code: 'save_error', message: '存储空间不足');
    await exportQuote(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('导出失败：存储空间不足'), findsOneWidget);
    expect(find.text('已导出项目报价单'), findsNothing);
  });

  testWidgets('Android quote export cancellation has no success message', (
    tester,
  ) async {
    savedUri = null;
    await exportQuote(tester);
    expect(tester.takeException(), isNull);
    expect(find.byType(SnackBar), findsNothing);
  });
}
