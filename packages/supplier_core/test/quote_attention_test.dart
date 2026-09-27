import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('quote_attention'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('shows the next 30 days and products without a recent quote', () {
    final s = device('A');
    final supplierId = s.save('supplier', supplier('甲'));
    final projectId = s.save('project', project('P1'));
    String add(String name, String quotedOn, {String? validUntil}) {
      final productId = s.save('product', product(name));
      s.save(
        'quotation',
        quotation(
          supplierId,
          productId,
          projectId,
          '10',
          quotedOn: quotedOn,
          validUntil: validUntil,
        ),
      );
      return productId;
    }

    final explicit = add('明确到期', '2026-09-01', validUntil: '2026-10-01');
    final implicit = add('默认到期', '2026-07-01'); // 90-day default
    final stale = add('长期未更新', '2026-05-01');
    add('近期报价', '2026-09-20');
    add('已经过期', '2026-01-01', validUntil: '2026-02-01');
    s.save('product', product('从未报价'));

    final a = s.quoteAttention(asOf: DateTime.utc(2026, 9, 27), limit: 1);
    expect(a.expiringCount, 2);
    expect(a.expiring, hasLength(1));
    expect(a.expiring.single.data['product_id'], implicit);
    expect(a.expiring.single.data['expires_on'], '2026-09-29');
    expect(a.staleProductCount, 2);
    expect(a.staleProducts, hasLength(1));
    expect(a.staleProducts.single.data['last_quoted_on'], '2026-01-01');

    final all = s.quoteAttention(asOf: DateTime.utc(2026, 9, 27));
    expect(all.expiring.map((h) => h.data['product_id']), [implicit, explicit]);
    expect(all.staleProducts.map((h) => h.id), contains(stale));
  });

  test('deleted and informal quotations do not trigger reminders', () {
    final s = device('A');
    final supplierId = s.save('supplier', supplier('甲'));
    final projectId = s.save('project', project('P1'));
    final productId = s.save('product', product('泵'));
    final deleted = s.save(
      'quotation',
      quotation(
        supplierId,
        productId,
        projectId,
        '10',
        quotedOn: '2026-09-01',
        validUntil: '2026-10-01',
      ),
    );
    s.delete('quotation', deleted);
    s.save('quotation', {
      ...quotation(
        supplierId,
        productId,
        projectId,
        '10',
        quotedOn: '2026-09-01',
        validUntil: '2026-10-01',
      ),
      'price_basis': 'reference',
    });
    final a = s.quoteAttention(asOf: DateTime.utc(2026, 9, 27));
    expect(a.expiringCount, 0);
    expect(a.staleProductCount, 0);
  });

  test('future-dated quotation cannot hide an older stale quotation', () {
    final s = device('A');
    final supplierId = s.save('supplier', supplier('甲'));
    final projectId = s.save('project', project('P1'));
    final productId = s.save('product', product('旧报价物料'));
    final futureOnlyId = s.save('product', product('只有未来报价'));
    for (final (id, date) in [
      (productId, '2026-05-01'),
      (productId, '2026-12-01'),
      (futureOnlyId, '2026-12-01'),
    ]) {
      s.save(
        'quotation',
        quotation(supplierId, id, projectId, '10', quotedOn: date),
      );
    }
    final attention = s.quoteAttention(asOf: DateTime.utc(2026, 9, 27));
    expect(attention.staleProductCount, 1);
    expect(attention.staleProducts.single.id, productId);
    expect(attention.staleProducts.single.data['last_quoted_on'], '2026-05-01');
  });
}
