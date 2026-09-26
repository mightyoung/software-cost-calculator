import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_mi'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('cleanOffer normalizes what the model wrote', () {
    Offer clean(Map<String, Object?> raw) =>
        cleanOffer({'name': '泵', 'unit': '台', ...raw});
    expect(clean({'price': '¥1.2万'})['price'], '12000');
    expect(clean({'price': '12,500.50元'})['price'], '12500.5');
    expect(clean({'price': 3200})['price'], '3200');
    final talk = clean({'price': '面议', 'notes': '含运费'});
    expect(talk['price'], isNull);
    expect(talk['notes'], '含运费；报价原文：面议');
    expect(clean({'currency': 'RMB'})['currency'], 'CNY');
    expect(clean({'currency': 'usd'})['currency'], 'USD');
    expect(clean({'tax_mode': '含税'})['tax_mode'], 'unknown');
    expect(clean({'tax_rate': '13%'})['tax_rate'], '13');
    expect(clean({'quoted_on': '9月20日'})['quoted_on'], isNull);
    final dates = clean({
      'quoted_on': '2026-09-20',
      'valid_until': '2026-09-01',
    });
    expect(dates['valid_until'], isNull);
    expect(dates['notes'], '有效期原文：2026-09-01');
    expect(clean({'lead_time_days': '约15天'})['lead_time_days'], isNull);
    expect(clean({'name': '  '})['name'], isNull);
  });

  test(
    'pasted offers become suppliers, contacts, products and quotes',
    () async {
      final s = device('A');
      final known = s.save('supplier', supplier('甲泵业'));
      final pump = s.save('product', {
        ...product('立式多级泵', unit: '台'),
        'brand': '格兰富',
        'model': 'CR10-5',
      });
      final pro = s.save('project', project('P1'));

      final model = FakeModel([
        jsonReply({
          'offers': [
            {
              'supplier': '甲泵业',
              'contact_name': '张三',
              'phone': '13800000000',
              'name': '多级离心泵',
              'brand': '格兰富',
              'model': 'cr10-5',
              'unit': '台',
              'price': '12,500',
              'tax_mode': 'included',
              'qty': '2',
              'quoted_on': '2026-08-20',
            },
            {
              'supplier': '乙阀门有限公司',
              'contact_name': '李四',
              'wechat': 'lisi_valve',
              'name': '闸阀',
              'specification': 'DN100 PN16',
              'unit': '个',
              'price': '860',
              'tax_mode': 'excluded',
              'qty': '约4',
            },
            {
              'supplier': '乙阀门有限公司',
              'contact_name': '李四',
              'wechat': 'lisi_valve',
              'name': '蝶阀',
              'specification': 'DN150',
              'unit': '个',
              'price': '面议',
            },
            {'supplier': '丙公司', 'name': '无名配件'},
          ],
        }),
      ]);
      final offers = await s.extractOffers(model.client, '一段报价文字');
      expect(offers, hasLength(4));
      final plans = [for (final o in offers) s.planOffer(o)];
      expect(plans[0].supplierId, known);
      expect(plans[0].productId, pump, reason: 'same brand and model');
      expect(plans[1].supplierId, isNull);
      expect(plans[1].productId, isNull);
      expect(plans[3].error, '缺少单位');
      expect([for (final p in plans.take(3)) p.error], [null, null, null]);

      final choices = [
        for (final p in plans.take(3))
          (offer: p.offer, supplierId: p.supplierId, productId: p.productId),
      ];
      final summary = s.applyOffers(
        choices,
        projectId: pro,
        inquirer: '王五',
        addToBudget: true,
      );
      expect(summary, (
        suppliers: 1,
        contacts: 2,
        products: 2,
        quotations: 2,
        duplicates: 0,
        items: 3,
      ));
      final quotes = s.listQuotations(projectId: pro);
      expect(quotes, hasLength(2));
      final pumpQuote = quotes.singleWhere((q) => q.data['product_id'] == pump);
      expect(pumpQuote.data['price'], '12500');
      expect(pumpQuote.data['inquirer_name'], '王五');
      expect(
        (pumpQuote.data['contact_snapshot']! as Map)['phone'],
        '13800000000',
      );

      final b = s.budget(pro, asOf: DateTime.utc(2026, 9, 2));
      final lines = {for (final l in b.lines) l.data['product_id']: l.data};
      expect(lines[pump]!['unit_cost'], '12500');
      expect(lines[pump]!['qty'], '2');
      final valve = lines.values.singleWhere(
        (l) => l['product_id'] != pump && l['qty'] == '4',
      );
      expect(valve['unit_cost'], '0', reason: 'excluded-tax quote vs project');
      expect(valve['notes'], contains('与项目口径不同'));

      // Importing the same information again adds no quotations.
      final again = [for (final o in offers.take(3)) s.planOffer(o)];
      expect(again.every((p) => p.supplierId != null), isTrue);
      final second = s.applyOffers(
        [
          for (final p in again)
            (offer: p.offer, supplierId: p.supplierId, productId: p.productId),
        ],
        projectId: pro,
        inquirer: '王五',
      );
      expect(second.quotations, 0);
      expect(second.duplicates, 2);
      expect(second.suppliers, 0);
      expect(second.contacts, 0);
    },
  );

  test('offerError explains what blocks an import', () {
    final s = device('A');
    Offer offer(Map<String, String?> extra) =>
        cleanOffer({'supplier': '甲', 'name': '泵', 'unit': '台', ...extra});
    expect(s.offerError(offer({})), isNull);
    expect(s.offerError(offer({'supplier': null})), '缺少供应商名称');
    expect(s.offerError({...offer({}), 'price': '1234567890123'}), '单价有误');
  });
}
