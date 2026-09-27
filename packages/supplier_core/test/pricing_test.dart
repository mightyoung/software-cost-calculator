import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_pricing'));
  tearDown(() => tmp.deleteSync(recursive: true));

  late Store s;
  late String sup, prod, pro, other;
  final asOf = DateTime.utc(2026, 9, 10);
  setUp(() {
    s = device('A');
    sup = s.save('supplier', supplier('甲'));
    prod = s.save('product', product('泵'));
    pro = s.save('project', project('P1'));
    other = s.save('project', project('P2'));
  });

  test('extra cost spreads over the quantity needed', () {
    final lump = s.save('quotation', {
      ...quotation(sup, prod, pro, '100'),
      'extra_cost': '50',
    });
    final plain = s.save('quotation', quotation(sup, prod, pro, '110'));
    // 2 units: 100 + 50/2 = 125 > 110.
    final two = s.quoteOptions(pro, prod, asOf: asOf, qty: '2');
    expect(two.map((o) => o.id), [plain, lump]);
    expect(two.last.effectivePrice, '125');
    // 10 units: 100 + 5 = 105 < 110.
    expect(s.quoteOptions(pro, prod, asOf: asOf, qty: '10').first.id, lump);
  });

  test('an award for this project comes first and prices at the deal', () {
    final cheap = s.save('quotation', quotation(sup, prod, pro, '80'));
    final elsewhere = s.save('quotation', {
      ...quotation(sup, prod, other, '95'),
      'awarded_on': '2026-09-02',
      'deal_price': '90',
    });
    final ours = s.save('quotation', {
      ...quotation(sup, prod, pro, '100'),
      'awarded_on': '2026-09-03',
      'deal_price': '93',
    });
    final options = s.quoteOptions(pro, prod, asOf: asOf);
    expect(options.map((o) => o.id), [ours, elsewhere, cheap]);
    expect(options.first.price, '93');
    expect(options.first.awarded, isTrue);

    // Priced at the award, the 80 quote is more than 10% cheaper: warn.
    s.save(
      'project_item',
      item(pro, 'material', productId: prod, quotationId: ours, cost: '93'),
    );
    expect(s.budget(pro, asOf: asOf).lines.single.warnings, [
      'cheaper_available',
    ]);
  });

  test('history summarizes comparable prices and flags outliers', () {
    for (final (price, day) in [('100', '01'), ('120', '02'), ('110', '03')]) {
      s.save(
        'quotation',
        quotation(sup, prod, pro, price, quotedOn: '2026-09-$day'),
      );
    }
    s.save('quotation', {
      ...quotation(sup, prod, pro, '118', quotedOn: '2026-09-04'),
      'awarded_on': '2026-09-05',
      'deal_price': '105',
    });
    s.save('quotation', quotation(sup, prod, pro, '1', currency: 'USD'));
    final h = s.priceHistory(
      prod,
      currency: 'CNY',
      taxMode: 'included',
      unit: '件',
    )!;
    expect(h.count, 4);
    expect(h.min, '100');
    expect(h.max, '120');
    expect(h.average, '108.75'); // 100 + 120 + 110 + 105 (deal), / 4
    expect(h.lastDeal, '105');
    expect(h.deviationPercent('130.5'), 20);
    expect(h.deviationPercent('100'), -8);
    expect(
      s.priceHistory(prod, currency: 'EUR', taxMode: 'included', unit: '件'),
      isNull,
    );
  });
}
