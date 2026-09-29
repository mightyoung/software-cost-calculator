import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/catalog/catalog_page.dart';
import 'package:supplier_app/features/catalog/contacts.dart';
import 'package:supplier_app/features/catalog/detail_panel.dart';
import 'package:supplier_app/features/inquiries/inquiry_create.dart';
import 'package:supplier_app/features/inquiries/inquiry_page.dart';
import 'package:supplier_app/features/projects/item_dialogs.dart';
import 'package:supplier_app/features/projects/project_detail.dart';
import 'package:supplier_app/features/projects/projects_page.dart';
import 'package:supplier_app/features/quotes/quotes_page.dart';
import 'package:supplier_app/features/inquiries/cell_dialog.dart';
import 'package:supplier_app/features/inquiries/award_dialog.dart';
import 'package:supplier_app/features/quotes/compare_view.dart';
import 'package:supplier_app/features/projects/project_form.dart';
import 'package:supplier_app/features/quotes/quote_form.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  for (final dark in [false, true]) {
    for (final form in ['project', 'supplier', 'product', 'quote']) {
      testWidgets('$form form at 390px and 1.4 text, dark=$dark', (
        tester,
      ) async {
        Tokens.dark = dark;
        addTearDown(() => Tokens.dark = false);
        final dir = Directory.systemTemp.createTempSync('business_design');
        final store = Store.open('${dir.path}/test.db', device: 'test');
        final state = AppState.test(store, dir);
        addTearDown(() {
          store.close();
          dir.deleteSync(recursive: true);
        });
        tester.view.physicalSize = const Size(390, 844);
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
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('打开'),
                  onPressed: () {
                    switch (form) {
                      case 'project':
                        showProjectForm(context, state);
                      case 'quote':
                        showQuoteForm(context, state);
                      default:
                        showCatalogForm(context, state, form);
                    }
                  },
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (form == 'product') {
          await tester.enterText(find.byType(TextField).first, '离心泵');
          await tester.pumpAndSettle();
          final add = find.widgetWithText(TextButton, '添加');
          await tester.ensureVisible(add);
          await tester.tap(add);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        // Scroll through the complete dialog, including late sections and actions.
        final scroll = find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(SingleChildScrollView),
            )
            .last;
        for (var i = 0; i < 6; i++) {
          await tester.drag(scroll, const Offset(0, -450));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(store.searchByName('project', ''), isEmpty);
        expect(store.searchByName('supplier', ''), isEmpty);
        expect(store.searchByName('product', ''), isEmpty);
      });
    }
    for (final surface in [
      'compare',
      'contact',
      'inquiry-cell',
      'award',
      'budget-item',
      'inquiry-create',
      'inquiry',
      'supplier-detail',
      'product-detail',
      'projects',
      'project-detail',
      'quotes',
    ]) {
      testWidgets('$surface populated at 390px, large text and dark=$dark', (
        tester,
      ) async {
        Tokens.dark = dark;
        addTearDown(() => Tokens.dark = false);
        final dir = Directory.systemTemp.createTempSync('business_populated');
        final store = Store.open('${dir.path}/test.db', device: 'test');
        final state = AppState.test(store, dir);
        addTearDown(() {
          store.close();
          dir.deleteSync(recursive: true);
        });
        Map<String, Object?> data(
          List<String> fields,
          Map<String, Object?> values,
        ) => {for (final f in fields) f: null, ...values};
        final supplier = store.save(
          'supplier',
          data(Supplier.fields, {
            'name': '上海工业设备供应商',
            'aliases': <String>[],
            'categories': <String>[],
          }),
        );
        final product = store.save(
          'product',
          data(Product.fields, {'name': '工业离心泵', 'unit': '台'}),
        );
        final project = store.save(
          'project',
          data(Project.fields, {
            'name': '泵房',
            'code': 'P1',
            'status': 'active',
            'currency': 'CNY',
            'tax_mode': 'included',
            'markup_rate': '0',
          }),
        );
        final item = store.save(
          'project_item',
          data(ProjectItem.fields, {
            'project_id': project,
            'product_id': product,
            'category': 'material',
            'qty': '2',
            'unit': '台',
            'unit_cost': '0',
          }),
        );
        final inquiry = store.createInquiry(
          project,
          '泵询价',
          itemIds: [item],
          supplierIds: [supplier],
        );
        store.quoteForInquiry(
          inquiry,
          item,
          supplier,
          price: '3200',
          context: (inquirer: '王工', asOf: null),
        );
        final quotation = store.listQuotations(productId: product).single.id;
        final choices = [
          (quotationId: quotation, label: '报价方案 0 · 工业离心泵 ¥3,200 / 台'),
          for (var i = 1; i < 8; i++)
            (
              quotationId: store.save('quotation', {
                ...store.get('quotation', quotation)!.data,
                'quoted_on': '2026-09-${10 + i}',
              }),
              label: '报价方案 $i · 工业离心泵 ¥3,200 / 台',
            ),
        ];
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: const TextScaler.linear(1.4),
                disableAnimations: true,
                viewInsets: surface == 'contact'
                    ? const EdgeInsets.only(bottom: 300)
                    : EdgeInsets.zero,
              ),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: switch (surface) {
                  'compare' => CompareView(
                    state: state,
                    productId: product,
                    onClose: () {},
                  ),
                  'supplier-detail' => CatalogDetail(
                    state: state,
                    type: 'supplier',
                    id: supplier,
                  ),
                  'product-detail' => CatalogDetail(
                    state: state,
                    type: 'product',
                    id: product,
                  ),
                  'inquiry' => InquiryPage(state: state, id: inquiry),
                  'projects' => ProjectsPage(state: state),
                  'project-detail' => ProjectDetail(
                    state: state,
                    projectId: project,
                    compact: true,
                  ),
                  'quotes' => QuotesPage(state: state),
                  _ => TextButton(
                    child: const Text('打开'),
                    onPressed: () {
                      switch (surface) {
                        case 'contact':
                          showContactForm(context, state, supplier);
                        case 'inquiry-cell':
                          showInquiryCell(
                            context,
                            state,
                            inquiryId: inquiry,
                            itemId: item,
                            supplierId: supplier,
                          );
                        case 'award':
                          showAwardDialog(context, state, choices: choices);
                        case 'budget-item':
                          showItemEditor(context, state, project, itemId: item);
                        case 'inquiry-create':
                          showCreateInquiry(context, state, project);
                      }
                    },
                  ),
                },
              ),
            ),
          ),
        );
        final isDialog = [
          'contact',
          'inquiry-cell',
          'award',
          'budget-item',
          'inquiry-create',
        ].contains(surface);
        if (isDialog) {
          await tester.tap(find.text('打开'));
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (surface == 'compare') {
          final horizontal = find.byWidgetPredicate(
            (w) =>
                w is SingleChildScrollView &&
                w.scrollDirection == Axis.horizontal,
          );
          expect(horizontal, findsOneWidget);
          await tester.drag(horizontal, const Offset(-450, 0));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        } else if (isDialog) {
          await tester.tap(find.text('取消').last);
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
        }
        expect(store.get('project_item', item)!.data['unit_cost'], '0');
      });
    }
  }
}
