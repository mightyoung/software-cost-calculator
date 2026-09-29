import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/home/home_page.dart';
import 'package:supplier_app/features/projects/project_detail.dart';
import 'package:supplier_app/features/projects/projects_page.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  late Directory dir;
  late AppState state;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('task_surfaces_test');
    final store = Store.open('${dir.path}/test.db', device: '测试机');
    for (final (name, status) in [
      ('进行中的项目', 'active'),
      ('策划中的项目', 'planning'),
    ]) {
      store.save('project', {
        for (final field in Project.fields) field: null,
        'name': name,
        'code': status,
        'status': status,
        'currency': 'CNY',
        'tax_mode': 'included',
        'markup_rate': '15',
      });
    }
    state = AppState.test(store, dir);
  });

  tearDown(() {
    state.store.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester, Widget child, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('home search opens command palette by touch on a phone', (
    tester,
  ) async {
    await mount(
      tester,
      HomePage(state: state, onGo: (_) {}),
      const Size(390, 844),
    );
    await tester.tap(find.text('搜索项目、供应商或报价'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), '打开 项目');
    await tester.pumpAndSettle();
    expect(find.text('打开 项目'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('default and filtered detail have a matching selected project', (
    tester,
  ) async {
    await mount(tester, ProjectsPage(state: state), const Size(1200, 900));
    bool isSelected(String name) => tester
        .widgetList<Semantics>(
          find.ancestor(of: find.text(name), matching: find.byType(Semantics)),
        )
        .any((widget) => widget.properties.selected == true);
    expect(find.byType(ProjectDetail), findsOneWidget);
    expect(isSelected('进行中的项目'), isTrue);
    await tester.tap(find.text('策划中'));
    await tester.pumpAndSettle();
    expect(isSelected('策划中的项目'), isTrue);
    expect(find.text('进行中的项目'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'project layout uses available width and keeps touch filters usable',
    (tester) async {
      await mount(
        tester,
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 390, child: ProjectsPage(state: state)),
        ),
        const Size(1400, 900),
      );
      expect(find.byType(ProjectDetail), findsNothing);
      expect(find.text('新建项目'), findsOneWidget);
      expect(find.text('从清单生成'), findsOneWidget);
      final filter = find
          .ancestor(of: find.text('进行中'), matching: find.byType(InkWell))
          .first;
      expect(tester.getSize(filter).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    },
  );
}
