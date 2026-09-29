import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_resp'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('requirement → budget → inquiry sheet → answers judged per clause', () {
    final s = device('A');
    final pro = s.save('project', project('P1'));
    final jia = s.save('supplier', supplier('甲'));
    final yi = s.save('supplier', supplier('乙'));
    final req = s.createSpecRequest('泵房', [
      draftItem(
        '温湿度传感器',
        '（1）测量范围：温度-20℃~+80℃\n★（2）防护等级不低于IP65\n（3）与采集器适配',
        qty: '25',
        unit: '个',
      ),
    ], projectId: pro);

    // 加入预算: a line still to be inquired, requirement in its notes.
    expect(s.addItemsToBudget(req), 1);
    expect(s.addItemsToBudget(req), 0, reason: 'already linked');
    final item = s.specItemsOf(req).single;
    final line = s.get(
      'project_item',
      item.data['project_item_id']! as String,
    )!;
    expect(line.data['qty'], '25');
    expect(line.data['notes'], startsWith('要求：（1）测量范围'));

    final inq = s.createInquiry(
      pro,
      '传感器询价',
      itemIds: [line.id],
      supplierIds: [jia, yi],
    );
    final sheet = readXlsx(s.exportInquirySheet(inq, jia)).sheets.last;
    expect(sheet.name, '技术响应');
    final header = sheet.rows[2].map((c) => c.display).toList();
    expect(header, responseSheetColumns);
    expect(sheet.rows.skip(3).map((r) => r[3].display), ['', '★', '']);

    // What the suppliers send back.
    List<List<Object?>> answers(List<(String?, String?)> filled) => [
      ['技术响应'],
      [],
      responseSheetColumns,
      for (final (i, (value, dev)) in filled.indexed)
        [
          Num('1'),
          '温湿度传感器',
          Num('${i + 1}'),
          '',
          '',
          value,
          dev,
          null,
          item.id,
        ],
    ];
    final fromJia = s.planSpecResponses(
      writeXlsx([
        SheetData(
          '技术响应',
          answers([
            ('-40~85℃', '无偏离'),
            ('IP54', '无偏离'),
            ('RS485，适配各类采集器', '无偏离'),
          ]),
        ),
      ]),
      inq,
    )!;
    expect(fromJia.single.rows, hasLength(3));
    expect(s.applySpecResponses(fromJia, jia, inquiryId: inq), 3);
    final fromYi = s.planSpecResponses(
      writeXlsx([
        SheetData(
          '技术响应',
          answers([('-10~60℃', '负偏离'), ('外壳防护 IP66', null), (null, null)]),
        ),
      ]),
      inq,
    )!;
    s.applySpecResponses(fromYi, yi, inquiryId: inq);

    final byName = {
      for (final r in s.responsesOf(item.id))
        s.get('supplier', r.data['supplier_id']! as String)!.data['name']: s
            .checkResponse(item, r),
    };
    final a = byName['甲']!, b = byName['乙']!;
    expect(
      [for (final c in a) c.checked],
      [Outcome.better, Outcome.worse, Outcome.exact],
    );
    expect(a[1].contradicted, isTrue, reason: 'IP54 claimed as 无偏离');
    expect(a[1].why, isNotNull);
    expect(
      [for (final c in b) c.checked],
      [Outcome.worse, Outcome.better, Outcome.unknown],
    );
    expect(b[0].why, contains('下限不够'));
    expect(b.any((c) => c.contradicted), isFalse);

    // Answering one clause again replaces only that answer.
    s.applySpecResponses(
      s.planSpecResponses(
        writeXlsx([
          SheetData('技术响应', [
            ['技术响应'],
            [],
            responseSheetColumns,
            [Num('1'), '', Num('2'), '', '', 'IP66', '正偏离', null, item.id],
          ]),
        ]),
        inq,
      )!,
      jia,
    );
    final again = s.checkResponse(
      item,
      s.get('spec_response', responseRecordId(item.id, jia))!,
    );
    expect(
      [for (final c in again) c.checked],
      [Outcome.better, Outcome.better, Outcome.exact],
    );

    final book = readXlsx(s.supplierDeviationXlsx(req));
    final summary = book.sheets.first.rows;
    expect(summary[2].map((c) => c.display), [
      '设备',
      '供应商',
      '负偏离',
      '待确认',
      '声明与数值不符',
    ]);
    expect(
      summary.skip(3).map((r) => (r[1].display, r[2].display, r[4].display)),
      [('甲', '0', '0'), ('乙', '1', '0')],
    );
    expect(book.sheets[1].rows[1].map((c) => c.display), contains('乙 偏离'));

    // A sheet without the technical part is not a response.
    expect(s.planSpecResponses(s.exportCostBudget(pro), inq), isNull);
  });

  test('stated deviation words', () {
    expect(statedOutcome('无偏离'), Outcome.exact);
    expect(statedOutcome('满足'), Outcome.exact);
    expect(statedOutcome('正偏离'), Outcome.better);
    expect(statedOutcome('不满足'), Outcome.worse);
    expect(statedOutcome('负偏离'), Outcome.worse);
    expect(statedOutcome('见附件'), isNull);
    expect(statedOutcome(null), isNull);
  });

  test('past choices per class form the selection library', () {
    final s = device('A');
    final p = s.save('product', {
      ...product('变送器', unit: '个'),
      'spec_class': 'sensor.th',
    });
    final req = s.createSpecRequest('x', [
      draftItem('温湿度传感器', '防护等级IP65'),
      draftItem('温湿度传感器', '防护等级IP66'),
      draftItem('工控机', 'CPU八核'),
    ]);
    final items = s.specItemsOf(req);
    s.chooseProduct(items[0].id, p);
    s.chooseProduct(items[1].id, p);
    expect(s.chosenCounts('sensor.th'), {p: 2});
    expect(s.chosenCounts('computer'), isEmpty);
  });
}
