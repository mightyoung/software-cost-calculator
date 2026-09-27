import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('compare'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('tax-inclusive normalized price controls group order and lowest', () {
    final s = device('A');
    final sup = s.save('supplier', supplier('甲'));
    final prod = s.save('product', product('泵'));
    final pro = s.save('project', project('P'));
    final included = s.save('quotation', quotation(sup, prod, pro, '110'));
    final excluded = s.save('quotation', {
      ...quotation(sup, prod, pro, '100'),
      'tax_mode': 'excluded',
    });
    final noRate = s.save('quotation', {
      ...quotation(sup, prod, pro, '99'),
      'tax_mode': 'excluded',
      'tax_rate': null,
    });
    final groups = s.compareQuotes(prod, asOf: DateTime.utc(2026, 9, 10));
    final rows = groups.firstWhere((g) => g.taxMode == 'included').rows;
    expect(rows.map((r) => r.id), [included, excluded]);
    expect(rows.first.lowest, isTrue);
    expect(rows.last.price, '100');
    expect(rows.last.comparisonPrice, '113');
    expect(rows.last.converted, isTrue);
    final groupHistory = s.priceHistory(
      prod,
      currency: 'CNY',
      taxMode: 'excluded',
      unit: '件',
      forCompareGroup: true,
    )!;
    expect(groupHistory.count, 1);
    expect(groupHistory.average, '99');
    expect(
      groups.firstWhere((g) => g.taxMode == 'excluded').rows.single.id,
      noRate,
    );
  });

  test('groups by basis, marks lowest valid, explains exclusions', () {
    final s = device('A');
    final a = s.save('supplier', supplier('甲'));
    final b = s.save('supplier', supplier('乙'));
    final gone = s.save('supplier', supplier('丙'));
    final prod = s.save('product', product('水泵'));
    final pro = s.save('project', project('P'));
    final asOf = DateTime.utc(2026, 9, 10);
    final cheapButExpired = s.save(
      'quotation',
      quotation(
        a,
        prod,
        pro,
        '80',
        quotedOn: '2026-08-01',
        validUntil: '2026-08-31',
      ),
    );
    final best = s.save('quotation', quotation(b, prod, pro, '95'));
    s.save(
      'quotation',
      quotation(
        a,
        prod,
        pro,
        '100',
        quotedOn: '2026-09-01',
        validUntil: '2026-12-31',
      ),
    );
    final stale = s.save(
      'quotation',
      quotation(a, prod, pro, '70', quotedOn: '2026-05-01'),
    );
    final unknownTax = s.save('quotation', {
      ...quotation(a, prod, pro, '60'),
      'tax_mode': 'unknown',
    });
    final deletedSupplier = s.save(
      'quotation',
      quotation(gone, prod, pro, '50'),
    );
    s.delete('supplier', gone);
    s.save('quotation', quotation(a, prod, pro, '12', currency: 'USD'));

    final groups = s.compareQuotes(prod, asOf: asOf);
    expect(groups.map((g) => '${g.currency}|${g.taxMode}'), [
      'CNY|included',
      'USD|included',
      'CNY|unknown',
    ]);
    final cny = groups.first.rows;
    expect(cny.first.id, best);
    expect(cny.first.lowest, isTrue);
    expect(cny.where((r) => r.lowest), hasLength(1));
    expect(cny.map((r) => r.valid), [true, true, false, false, false]);
    Map<String, List<QuoteIssue>> issues = {
      for (final r in cny) r.id: r.issues,
    };
    expect(issues[cheapButExpired], [QuoteIssue.expired]);
    expect(issues[stale], [QuoteIssue.stale]);
    expect(issues[deletedSupplier], [QuoteIssue.supplierDeleted]);
    expect(groups.last.rows.single.id, unknownTax);
    expect(groups.last.rows.single.issues, [QuoteIssue.taxUnknown]);
    expect(groups.last.rows.single.lowest, isFalse);
  });
}
