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

  test('tax conversion rounds exact decimals and refuses unknown bases', () {
    final q = {
      ...quotation(sup, prod, pro, '0.000001'),
      'tax_mode': 'excluded',
      'tax_rate': '50',
    };
    expect(priceInTaxMode(q, currency: 'CNY', taxMode: 'included'), '0.000002');
    expect(
      priceInTaxMode(
        {...q, 'price': '1', 'tax_mode': 'included', 'tax_rate': '13'},
        currency: 'CNY',
        taxMode: 'excluded',
      ),
      '0.884956',
    );
    expect(
      priceInTaxMode(
        {...q, 'tax_rate': '0'},
        currency: 'CNY',
        taxMode: 'included',
      ),
      '0.000001',
    );
    expect(
      priceInTaxMode(
        {...q, 'tax_rate': null},
        currency: 'CNY',
        taxMode: 'included',
      ),
      isNull,
    );
    expect(
      priceInTaxMode(
        {...q, 'tax_mode': 'unknown'},
        currency: 'CNY',
        taxMode: 'included',
      ),
      isNull,
    );
    expect(priceInTaxMode(q, currency: 'USD', taxMode: 'included'), isNull);
  });

  test('project options, awards and history share normalized unit prices', () {
    final q = s.save('quotation', {
      ...quotation(sup, prod, pro, '100'),
      'tax_mode': 'excluded',
      'extra_cost': '20',
    });
    s.save('quotation', {
      ...quotation(sup, prod, pro, '1'),
      'tax_mode': 'excluded',
      'tax_rate': null,
    });
    s.save('quotation', {
      ...quotation(sup, prod, pro, '1'),
      'tax_mode': 'unknown',
    });
    s.save('quotation', quotation(sup, prod, pro, '1', currency: 'USD'));
    final option = s.quoteOptions(pro, prod, asOf: asOf, qty: '2').single;
    expect(option.id, q);
    expect(option.price, '113');
    expect(option.sourcePrice, '100');
    expect(option.converted, isTrue);
    expect(
      option.effectivePrice,
      '124.3',
    ); // Tax-normalized extra remains comparison-only.
    final line = s.save('project_item', item(pro, 'material', productId: prod));
    expect(
      () => s.save(
        'project_item',
        item(pro, 'material', productId: prod, quotationId: q, cost: '100'),
      ),
      throwsA(isA<FormatException>()),
    );
    s.award(q, itemId: line, dealPrice: '90');
    expect(s.get('quotation', q)!.data['deal_price'], '90');
    expect(s.get('quotation', q)!.data['price'], '100');
    expect(s.get('project_item', line)!.data['unit_cost'], '101.7');
    final h = s.priceHistory(
      prod,
      currency: 'CNY',
      taxMode: 'included',
      unit: '件',
    )!;
    expect(h.count, 1);
    expect(h.average, '101.7');
    expect(h.lastDeal, '101.7');
    final reverse = s.quoteOptionsFor(
      prod,
      currency: 'CNY',
      taxMode: 'excluded',
      asOf: asOf,
    );
    expect(reverse.firstWhere((o) => o.id == q).price, '90');
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

  test('excluded project awards use net basis and keep existing snapshots', () {
    s.save('project', {
      ...s.get('project', pro)!.data,
      'tax_mode': 'excluded',
    }, id: pro);
    final q = s.save('quotation', quotation(sup, prod, pro, '113'));
    final line = s.save('project_item', item(pro, 'material', productId: prod));
    expect(s.quoteOptions(pro, prod, asOf: asOf).single.price, '100');
    s.award(q, itemId: line);
    expect(s.get('project_item', line)!.data['unit_cost'], '100');
    s.save('quotation', {
      ...s.get('quotation', q)!.data,
      'deal_price': '226',
    }, id: q);
    s.save('project_item', {
      ...s.get('project_item', line)!.data,
      'qty': '2',
    }, id: line);
    expect(s.get('project_item', line)!.data['unit_cost'], '100');
    expect(s.refreshPlan(pro, asOf: asOf).single.newCost, '200');
    final missing = s.save('quotation', {
      ...quotation(sup, prod, pro, '1'),
      'tax_rate': null,
    });
    expect(
      () => s.award(missing, itemId: line),
      throwsA(isA<FormatException>()),
    );
    expect(s.get('quotation', missing)!.data['deal_price'], isNull);
    expect(s.get('project_item', line)!.data['unit_cost'], '100');
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
