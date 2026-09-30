import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/catalog/catalog_page.dart';
import 'package:supplier_app/features/catalog/detail_panel.dart';
import 'package:supplier_app/features/inquiries/inquiry_page.dart';
import 'package:supplier_app/features/quotes/quote_form.dart';
import 'package:supplier_app/features/projects/item_dialogs.dart';
import 'package:supplier_app/features/projects/project_detail.dart';
import 'package:supplier_app/features/projects/projects_page.dart';
import 'package:supplier_app/features/quotes/compare_view.dart';
import 'package:supplier_app/features/quotes/quotes_page.dart';
import 'package:supplier_core/supplier_core.dart';

/// Import → delete → re-import must leave project and quotation pages
/// readable: a picker whose chosen record has since gone must not crash.
void main() {
  late Directory dir;
  late Store store;
  late AppState state;
  late String project;

  Offer offer(String price) => cleanOffer({
    'supplier': '甲泵业',
    'contact_name': '张三',
    'phone': '13800000000',
    'name': '离心泵',
    'category': '泵',
    'brand': '格兰富',
    'model': 'CR10',
    'unit': '台',
    'price': price,
    'tax_mode': 'included',
    'qty': '2',
  });

  void import(String price) {
    final plan = store.planOffer(offer(price));
    store.applyOffers(
      [
        (
          offer: plan.offer,
          supplierId: plan.supplierId,
          productId: plan.productId,
        ),
      ],
      projectId: project,
      inquirer: '王工',
      addToBudget: true,
    );
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('import_cycle');
    store = Store.open('${dir.path}/m.db', device: '测试机');
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
  });

  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> show(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: page),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('pages survive deleting and re-importing', (tester) async {
    import('100');
    for (final h in store.listQuotations(limit: 100)) {
      store.delete('quotation', h.id);
    }
    for (final type in ['product', 'supplier']) {
      for (final h in store.searchByName(type, '', limit: 100)) {
        store.delete(type, h.id);
      }
    }
    import('120');
    import('130');
    final product = store.searchProducts(['离心泵'], limit: 5).first.id;
    for (final page in <Widget>[
      ProjectsPage(state: state),
      ProjectDetail(state: state, projectId: project),
      QuotesPage(state: state),
      CompareView(state: state, productId: product, onClose: () {}),
    ]) {
      await show(tester, page);
      expect(tester.takeException(), isNull, reason: '${page.runtimeType}');
    }
  });

  testWidgets('budget line whose quotation was deleted still opens', (
    tester,
  ) async {
    import('100');
    import('120');
    final line = store.budget(project).lines.first;
    expect(line.data['quotation_id'], isNotNull);
    store.delete('quotation', line.data['quotation_id']! as String);
    await show(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              showItemEditor(context, state, project, itemId: line.id),
          child: const Text('打开'),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('编辑预算行'), findsOneWidget);
  });

  testWidgets('quote list filtered by a project that is then deleted', (
    tester,
  ) async {
    import('100');
    await show(tester, QuotesPage(state: state));
    await tester.tap(find.text('全部项目').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('一期').last);
    await tester.pumpAndSettle();
    state.write((s) => s.delete('project', project));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('material list filtered by a category that is then emptied', (
    tester,
  ) async {
    import('100');
    await show(tester, CatalogPage(state: state, type: 'product'));
    await tester.tap(find.text('全部类别').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('泵').last);
    await tester.pumpAndSettle();
    state.write((s) {
      for (final h in s.searchByName('product', '', limit: 100)) {
        s.delete('product', h.id);
      }
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a project is deleted from its detail page', (tester) async {
    await show(tester, ProjectsPage(state: state));
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除项目'));
    await tester.pumpAndSettle();
    expect(store.get('project', project)!.deleted, isTrue);
    expect(find.text('撤销'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  Future<void> confirmDeletion(
    WidgetTester tester,
    String open,
    String label,
  ) async {
    await tester.tap(find.text(open));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, label));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets('a quotation is deleted from its own form', (tester) async {
    import('100');
    final quote = store.listQuotations().single.id;
    await show(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showQuoteForm(context, state, id: quote),
          child: const Text('打开'),
        ),
      ),
    );
    await confirmDeletion(tester, '打开', '删除报价');
    expect(store.get('quotation', quote)!.deleted, isTrue);
  });

  testWidgets('a material is deleted from its detail panel', (tester) async {
    import('100');
    final product = store.searchProducts(['离心泵']).single.id;
    await show(
      tester,
      CatalogDetail(state: state, type: 'product', id: product),
    );
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除物料'));
    await tester.pumpAndSettle();
    expect(store.get('product', product)!.deleted, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an inquiry is deleted from its page', (tester) async {
    import('100');
    final line = store.budget(project).lines.single.id;
    final supplier = store.searchByName('supplier', '甲泵业').single.id;
    final inquiry = store.createInquiry(
      project,
      '泵询价',
      itemIds: [line],
      supplierIds: [supplier],
    );
    await show(tester, InquiryPage(state: state, id: inquiry));
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除询价单'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除询价单'));
    await tester.pumpAndSettle();
    expect(store.get('inquiry', inquiry)!.deleted, isTrue);
    expect(tester.takeException(), isNull);
  });
}
