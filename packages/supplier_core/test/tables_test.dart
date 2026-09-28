import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_tables'));
  tearDown(() => tmp.deleteSync(recursive: true));

  late Store s;
  late String jia, yi, pump, valve, pro, q1, q2, q3;
  final asOf = DateTime.utc(2026, 9, 20);

  setUp(() {
    s = device('A');
    jia = s.save('supplier', supplier('甲泵业'));
    yi = s.save('supplier', supplier('乙机电'));
    s.save('contact', {
      'supplier_id': jia,
      'name': '张经理',
      'phone': '138',
      'wechat': null,
      'email': null,
      'notes': null,
    });
    pump = s.save('product', {...product('离心泵'), 'model': 'IS80'});
    valve = s.save('product', product('闸阀'));
    pro = s.save('project', project('P1'));
    q1 = s.save('quotation', quotation(jia, pump, pro, '100'));
    q2 = s.save(
      'quotation',
      quotation(yi, pump, pro, '90', quotedOn: '2026-09-10'),
    );
    q3 = s.save(
      'quotation',
      quotation(jia, valve, pro, '50', quotedOn: '2026-01-01'),
    );
    s.save('project_item', item(pro, 'material', productId: pump));
    s.award(q2, dealPrice: '88', on: asOf);
  });

  test('supplier rows carry contacts and quote counts', () {
    final rows = {for (final r in s.supplierRows()) r.id: r};
    expect(rows[jia]!.contacts, 1);
    expect(rows[jia]!.contactName, '张经理');
    expect(rows[jia]!.contactPhone, '138');
    expect(rows[jia]!.quotes, 2);
    expect(rows[jia]!.projects, 1, reason: 'both quotes are for P1');
    expect(rows[yi]!.awards, 1);
    expect(rows[yi]!.lastQuotedOn, '2026-09-10');
    expect(s.supplierRows(only: {yi}).single.id, yi);
  });

  test('product rows carry the latest quote and usage', () {
    final rows = {for (final r in s.productRows()) r.id: r};
    expect(rows[pump]!.quotes, 2);
    expect(rows[pump]!.suppliers, 2);
    expect(rows[pump]!.projects, 1);
    expect(rows[pump]!.lastQuote!['price'], '90', reason: 'quoted 2026-09-10');
    expect(rows[valve]!.projects, 0);
    final merged = s.save('product', product('闸阀 重复'));
    s.mergeInto('product', merged, valve);
    expect(s.productRows().map((r) => r.id), isNot(contains(merged)));
  });

  test('quote pages filter, sort and count in the database', () {
    QuotePage page({
      QuoteFilter filter = QuoteFilter.all,
      QuoteSort sort = QuoteSort.quotedOn,
      bool descending = true,
      int limit = 200,
      Set<String>? products,
      Set<String>? suppliers,
      String? project,
    }) => s.quoteRows(
      filter: filter,
      sort: sort,
      descending: descending,
      limit: limit,
      productIds: products,
      supplierIds: suppliers,
      projectId: project,
      asOf: asOf,
    );

    expect(page().total, 3);
    expect(page(limit: 1).total, 3, reason: 'total ignores the page size');
    expect(page(limit: 1).rows.single.id, q2, reason: 'newest first');
    expect(
      page(sort: QuoteSort.price, descending: false).rows.map((r) => r.id),
      [q3, q2, q1],
      reason: 'the awarded one sorts at its deal price',
    );
    expect(page(filter: QuoteFilter.expired).rows.single.id, q3);
    expect(page(filter: QuoteFilter.usable).rows.map((r) => r.id).toSet(), {
      q1,
      q2,
    });
    expect(page(filter: QuoteFilter.awarded).rows.single.id, q2);
    expect(page(project: pro).total, 3);
    expect(page(project: s.save('project', project('P2'))).total, 0);
    expect(page(products: {valve}).rows.single.id, q3);
    expect(page(suppliers: {yi}).rows.single.id, q2);
    final r = page(products: {pump}, sort: QuoteSort.supplier).rows;
    // Code-point order: 乙 (U+4E59) < 甲 (U+7532); descending puts 甲 first.
    expect(r.map((x) => x.supplier), ['甲泵业', '乙机电']);
    expect(r.first.product, '离心泵');
    expect(r.first.model, 'IS80');
    expect(page(filter: QuoteFilter.expired).rows.single.issues, [
      QuoteIssue.stale,
    ]);
  });
}
