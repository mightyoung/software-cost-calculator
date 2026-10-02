import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_mi'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a material list imports only materials', () {
    final s = device('A');
    final table = tableFromText(
      '物料名称\t类型\t品牌\t型号\t技术参数\t单位\t供应商\t联系电话\t单价\n'
      '闸阀\t阀门\t威乐\tZ41\tDN100 PN16\t个\t乙阀门\t13900000000\t800\n'
      '电缆\t线缆\t远东\tYJV\t3x95\t米\t\t\t\n',
    )!;
    final offers = offersFromWorkbook(table, materials: true)!;
    final plans = [for (final o in offers) s.planOffer(materialOffer(o))];
    expect(plans.map((p) => p.error), everyElement(isNull));
    final sum = s.applyOffers(
      [
        for (final p in plans)
          (offer: p.offer, supplierId: p.supplierId, productId: p.productId),
      ],
      projectId: null,
      inquirer: '-',
    );
    expect(
      (sum.products, sum.suppliers, sum.contacts, sum.quotations),
      (2, 0, 0, 0),
    );
    final valve = s.searchProducts(['闸阀']).single.data;
    expect(valve['category'], '阀门');
    expect(valve['specification'], 'DN100 PN16');
    // Without a price or brand column it is still a material list.
    expect(
      offersFromWorkbook(
        tableFromText('名称\t技术参数\n泵\t10m3/h\n')!,
        materials: true,
      ),
      hasLength(1),
    );
  });

  test('quote sheet headers: 报价人, 报价公司, 报价时间', () {
    final offer = offersFromWorkbook(
      tableFromText(
        '物料名称\t单位\t单价\t数量\t报价公司\t报价人\t报价人联系方式\t报价时间\n'
        '闸阀\t个\t800\t3\t乙阀门\t王五\t13900000000\t2026-09-01\n',
      )!,
    )!.single;
    expect(
      [
        for (final k in [
          'supplier',
          'contact_name',
          'phone',
          'quoted_on',
          'qty',
        ])
          offer[k],
      ],
      ['乙阀门', '王五', '13900000000', '2026-09-01', '3'],
    );
  });

  test('a quote sheet\'s 数量 is the minimum order', () {
    final s = device('A');
    final pro = s.save('project', project('P-1'));
    final o = cleanOffer({
      'supplier': '乙阀门',
      'name': '闸阀',
      'unit': '个',
      'price': '800',
      'qty': '5个',
    });
    final p = s.planOffer(o);
    s.applyOffers(
      [(offer: o, supplierId: p.supplierId, productId: p.productId)],
      projectId: pro,
      inquirer: '王工',
    );
    expect(s.listQuotations().single.data['min_qty'], '5');
  });

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
    expect(s.offerError(offer({'supplier': null})), isNull, reason: '只登记物料');
    expect(s.offerError({...offer({}), 'price': '1234567890123'}), '单价有误');
  });

  test('values missing from the source are flagged; source is attached', () {
    final s = device('A');
    final pro = s.save('project', project('P1'));
    const source = '甲泵业 张经理 138-0000-0000\n格兰富 CR10-5 含税 1.2万/台\n乙阀门 闸阀 3,200元';
    final ok = cleanOffer({
      'supplier': '甲泵业',
      'phone': '13800000000',
      'name': '泵',
      'brand': '格兰富',
      'model': 'CR10-5',
      'unit': '台',
      'price': '1.2万',
    });
    expect(s.planOffer(ok, source: source).unverified, isEmpty);
    final bad = cleanOffer({
      'supplier': '乙阀门',
      'name': '闸阀',
      'model': 'Z41H',
      'unit': '个',
      'price': '3300',
    });
    expect(s.planOffer(bad, source: source).unverified, {'price', 'model'});
    // A misread digit must not hide inside a longer number of the source.
    final misread = cleanOffer({...bad, 'model': null, 'price': '320'});
    expect(s.planOffer(misread, source: source).unverified, {'price'});
    expect(s.planOffer(bad).unverified, isEmpty, reason: 'no source, no check');

    final plan = s.planOffer(ok, source: source);
    s.applyOffers(
      [(offer: plan.offer, supplierId: null, productId: null)],
      projectId: pro,
      inquirer: '王五',
      source: (name: '微信聊天.txt', bytes: utf8.encode(source)),
    );
    final q = s.listQuotations(projectId: pro).single.data;
    final att = s.attachmentsOf(q['attachment_ids'] as List).single;
    expect(att.name, '微信聊天.txt');
    expect(utf8.decode(s.attachment(att.id)!.bytes!), source);
  });

  test('a selection sheet imports without AI and creates what is missing', () {
    final s = device('A');
    final pro = s.save('project', project('P1'));
    // Shaped like a real selection list: no supplier column, merged cells
    // (blank continuation rows), a total row, contact words instead of phones.
    final book = readXlsx(
      writeXlsx([
        SheetData('Sheet1', [
          [
            '序号',
            '系统名称',
            '设备类别',
            '设备名称',
            '品牌',
            '型号',
            '主要指标要求',
            '单位',
            '数量',
            '单价',
            '联系人',
            '联系方式',
            '备注',
          ],
          [
            Num('1'),
            '温湿度',
            '硬件',
            '温湿度传感器',
            '永安',
            'YAWS-200',
            '技术指标：',
            '个',
            Num('25'),
            Num('400'),
            '牛工',
            Num('13812508860'),
            '含备件',
          ],
          [
            null,
            null,
            null,
            null,
            null,
            null,
            '（1）防护等级IP65',
            null,
            null,
            null,
            null,
            null,
            null,
          ],
          [
            Num('2'),
            null,
            '硬件',
            '探头',
            '果宇',
            'GY-1',
            null,
            '个',
            Num('4'),
            Num('3900'),
            '谢',
            '微信',
            null,
          ],
          [
            Num('3'),
            null,
            '硬件',
            '工控机',
            null,
            null,
            '八核',
            '台',
            Num('5'),
            Num('15000'),
            null,
            null,
            null,
          ],
          [
            '4',
            null,
            '硬件',
            '探头',
            '果宇',
            'GY-1',
            '长款',
            '个',
            Num('2'),
            Num('4100'),
            null,
            null,
            null,
          ],
          [
            null,
            '总价',
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
            null,
          ],
        ]),
      ]),
    );
    final offers = offersFromWorkbook(book)!;
    expect(offers, hasLength(4));
    expect(offers[0], containsPair('supplier', '永安'));
    expect(offers[0], containsPair('category', '硬件'));
    expect(offers[0], containsPair('phone', '13812508860'));
    expect(offers[0]['specification'], '技术指标：\n（1）防护等级IP65');
    expect(offers[1]['phone'], isNull);
    expect(offers[1]['notes'], '联系方式：微信');
    expect(offers[2]['supplier'], isNull);

    final plans = [for (final o in offers) s.planOffer(o)];
    expect([for (final p in plans) p.error], [null, null, null, null]);
    final sum = s.applyOffers(
      [
        for (final p in plans)
          (offer: p.offer, supplierId: p.supplierId, productId: p.productId),
      ],
      projectId: pro,
      inquirer: '王五',
      addToBudget: true,
    );
    expect(sum, (
      suppliers: 2,
      contacts: 1,
      products: 4,
      quotations: 3,
      duplicates: 0,
      items: 4,
    ));
    expect(s.searchByName('product', '工控机').single.data['category'], '硬件');
    // Importing the same sheet again matches everything it created, also
    // two materials that differ only in their specification.
    final again = [for (final o in offersFromWorkbook(book)!) s.planOffer(o)];
    expect(again.every((p) => p.productId != null), isTrue);
    expect(
      offersFromWorkbook(
        readXlsx(
          writeXlsx([
            SheetData('x', [
              ['日期', '金额'],
            ]),
          ]),
        ),
      ),
      isNull,
    );
  });

  test('repeated offers are dropped and applied once', () {
    final s = device('A');
    Offer o(String name, String model) => {
      for (final k in offerFields.keys) k: null,
      'name': name,
      'model': model,
      'unit': '个',
    };
    final offers = dedupeOffers([
      o('闸阀', 'Z41'),
      o('闸 阀', 'z-41'),
      o('球阀', 'Q1'),
    ]);
    expect(offers, hasLength(2));
    // Same model under a different name: still the one stored material.
    final sum = s.applyOffers(
      [
        for (final x in [o('闸阀', 'Z41'), o('DN100闸阀', 'Z41')])
          (offer: x, supplierId: null, productId: null),
      ],
      projectId: null,
      inquirer: '-',
    );
    expect(sum.products, 1);
  });
}
