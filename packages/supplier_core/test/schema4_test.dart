import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_v4'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('verbal and reference prices are shown but never budget prices', () {
    final s = device('A');
    final sup = s.save('supplier', supplier('甲'));
    final prod = s.save('product', product('泵'));
    final pro = s.save('project', project('P1'));
    final formal = s.save('quotation', quotation(sup, prod, pro, '100'));
    final verbal = s.save('quotation', {
      ...quotation(sup, prod, pro, '80'),
      'price_basis': 'verbal',
    });
    expect(
      () => s.save('quotation', {
        ...quotation(sup, prod, pro, '1'),
        'price_basis': 'guess',
      }),
      throwsFormatException,
    );
    final asOf = DateTime.utc(2026, 9, 10);
    final options = s.quoteOptions(pro, prod, asOf: asOf);
    expect(options.first.id, formal);
    expect(options.last.id, verbal);
    expect(options.last.valid, isFalse);
    final rows = s.compareQuotes(prod, asOf: asOf).single.rows;
    expect(rows.last.issues, [QuoteIssue.informal]);
    expect(rows.first.lowest, isTrue);
  });

  test(
    'key attributes: canonical, suggested per category, used for duplicates',
    () {
      final s = device('A');
      Map<String, Object?> pump(Map<String, String> attrs) => {
        ...product('离心泵', unit: '台'),
        'category': '泵',
        'attributes': attrs,
      };
      final a = s.save('product', pump({'流量': '50m³/h', '扬程': '32m'}));
      s.save('product', pump({'流量': '100m³/h', '材质': '304'}));
      expect(s.get('product', a)!.data['attributes'], {
        '流量': '50m³/h',
        '扬程': '32m',
      });
      expect(() => s.save('product', pump({'流量': ''})), throwsFormatException);
      expect(s.categoryAttributes('泵'), ['流量', '扬程', '材质']);
      expect(s.productCategories(), ['泵']);

      final same = s.similarProducts({
        'name': '离心泵',
        'category': '泵',
        'attributes': {'流量': '50 m³/h', '扬程': '32m'},
      });
      expect(same.first.hit.id, a);
      expect(same.first.level, Similarity.same);
      expect(s.searchProducts(['50m³/h']).first.id, a);
    },
  );
}
