import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_inquiry'));
  tearDown(() => tmp.deleteSync(recursive: true));

  late Store s;
  late String jia, yi, pro, pumpLine, valveLine, pump;
  final asOf = DateTime.utc(2026, 9, 10);
  setUp(() {
    s = device('A');
    jia = s.save('supplier', supplier('甲泵业'));
    yi = s.save('supplier', supplier('乙机电'));
    pump = s.save('product', {...product('离心泵', unit: '台'), 'model': 'IS80'});
    pro = s.save('project', project('P1'));
    pumpLine = s.save('project_item', {
      ...item(pro, 'material', productId: pump, qty: '2'),
      'unit': '台',
    });
    // A line still to be inquired: a name, no material yet.
    valveLine = s.save('project_item', {
      ...item(pro, 'material', name: '闸阀 DN100', qty: '4'),
      'unit': '个',
    });
  });

  test('matrix: quotes by cell, lowest valid per row, award fills budget', () {
    final inq = s.createInquiry(
      pro,
      '泵房设备询价',
      itemIds: [pumpLine, valveLine],
      supplierIds: [jia, yi],
    );
    final ctx = (inquirer: '王工', asOf: asOf);
    s.quoteForInquiry(inq, pumpLine, jia, price: '3200', context: ctx);
    s.quoteForInquiry(
      inq,
      pumpLine,
      yi,
      price: '3000',
      extraCost: '800',
      includes: const ['freight'],
      context: ctx,
    );
    s.quoteForInquiry(inq, valveLine, yi, price: '850', context: ctx);

    // The valve line got a material so it can carry quotations.
    final valve = s.get('project_item', valveLine)!.data['product_id'];
    expect(s.get('product', valve! as String)!.data['name'], '闸阀 DN100');

    final m = s.inquiryMatrix(inq, asOf: asOf);
    expect(m.suppliers, [jia, yi]);
    final pumpRow = m.rows.first;
    // 3000 + 800/2 = 3400 > 3200: 甲 is lowest.
    expect(pumpRow.cells[0]!.effectivePrice, '3200');
    expect(pumpRow.cells[1]!.effectivePrice, '3400');
    expect(pumpRow.cells[0]!.lowest, isTrue);
    expect(m.rows.last.cells[0], isNull, reason: '甲 has not quoted');
    expect(m.rows.last.cells[1]!.lowest, isTrue);
    expect(m.answered, {jia: 1, yi: 2});

    s.award(
      pumpRow.cells[0]!.quotationId,
      itemId: pumpLine,
      dealPrice: '3100',
      note: '含税价最低，交期短',
      on: asOf,
    );
    final line = s.get('project_item', pumpLine)!.data;
    expect(line['unit_cost'], '3100');
    expect(line['quotation_id'], pumpRow.cells[0]!.quotationId);
    expect(
      s.inquiryMatrix(inq, asOf: asOf).rows.first.cells[0]!.awarded,
      isTrue,
    );

    s.withdrawAward(pumpRow.cells[0]!.quotationId);
    expect(
      s.get('quotation', pumpRow.cells[0]!.quotationId)!.data['awarded_on'],
      isNull,
    );
  });

  test('matrix normalizes base and extra cost before ranking and history', () {
    final inq = s.createInquiry(
      pro,
      '税价比选',
      itemIds: [pumpLine],
      supplierIds: [jia, yi],
    );
    final ctx = (inquirer: '王工', asOf: asOf);
    s.quoteForInquiry(
      inq,
      pumpLine,
      jia,
      price: '100',
      taxMode: 'excluded',
      taxRate: '13',
      extraCost: '20',
      context: ctx,
    );
    s.quoteForInquiry(inq, pumpLine, yi, price: '124', context: ctx);
    s.save('quotation', {
      ...quotation(jia, pump, pro, '102'),
      'unit_snapshot': '台',
    });
    final cells = s.inquiryMatrix(inq, asOf: asOf).rows.single.cells;
    expect(cells[0]!.effectivePrice, '124.3');
    expect(cells[0]!.comparable, isTrue);
    expect(cells[1]!.lowest, isTrue);
    // History average (113 + 124 + 102) / 3 = 113; compare normalized 113.
    expect(cells[0]!.deviation, 0);
  });

  test('requote snapshots the current inquiry line unit', () {
    final inq = s.createInquiry(
      pro,
      '单位变更询价',
      itemIds: [pumpLine],
      supplierIds: [jia],
    );
    final ctx = (inquirer: '王工', asOf: asOf);
    final quoteId = s.quoteForInquiry(
      inq,
      pumpLine,
      jia,
      price: '100',
      context: ctx,
    );
    expect(s.get('quotation', quoteId)!.data['unit_snapshot'], '台');
    s.save('project_item', {
      ...s.get('project_item', pumpLine)!.data,
      'unit': '套',
    }, id: pumpLine);
    final requoted = s.quoteForInquiry(
      inq,
      pumpLine,
      jia,
      price: '110',
      context: ctx,
    );
    expect(requoted, quoteId);
    expect(s.get('quotation', quoteId)!.data['unit_snapshot'], '套');
  });

  test('inquiry sheet round trip for one supplier', () {
    final inq = s.createInquiry(
      pro,
      '泵房设备询价',
      itemIds: [pumpLine, valveLine],
      supplierIds: [jia, yi],
    );
    final sheet = s.exportInquirySheet(inq, yi);
    final book = readXlsx(sheet);
    final header = book.sheets.first.rows.firstWhere(
      (r) => r.any((c) => c.display == '单价'),
    );
    expect(header.map((c) => c.display), containsAll(['行号', '名称', '数量', '单价']));

    // The supplier fills in prices and sends the sheet back.
    final rows = [
      for (final r in book.sheets.first.rows) [for (final c in r) c.display],
    ];
    final h = rows.indexWhere((r) => r.contains('单价'));
    final col = {for (var i = 0; i < rows[h].length; i++) rows[h][i]: i};
    final filled = [
      for (var i = 0; i < rows.length; i++)
        if (i <= h)
          rows[i]
        else
          [
            for (var j = 0; j < rows[i].length; j++)
              j == col['单价']
                  ? (rows[i][col['名称']!].contains('闸阀') ? '860' : '')
                  : j == col['含税']
                  ? '含税'
                  : rows[i][j],
          ],
    ];
    final plan = s.planInquirySheet(
      writeXlsx([SheetData('询价', filled)]),
      inq,
      yi,
    );
    expect(plan.map((p) => (p.itemId, p.price)), [(valveLine, '860')]);
    expect(s.applyInquirySheet(inq, yi, plan, inquirer: '王工'), 1);
    expect(s.inquiryMatrix(inq, asOf: asOf).answered[yi], 1);
  });

  test('workbench: open inquiries by due date, replies, pending lines', () {
    final inq = s.createInquiry(
      pro,
      '泵房设备询价',
      itemIds: [pumpLine, valveLine],
      supplierIds: [jia, yi],
      dueDate: '2026-09-08',
    );
    final later = s.createInquiry(
      pro,
      '二期',
      itemIds: [pumpLine],
      supplierIds: [jia],
      dueDate: '2026-09-20',
    );
    s.quoteForInquiry(
      inq,
      pumpLine,
      jia,
      price: '3200',
      context: (inquirer: '王工', asOf: asOf),
    );
    final w = s.workbench(asOf: asOf);
    expect([for (final i in w.inquiries) i.id], [inq, later]);
    expect(w.inquiries.first.daysLeft, -2, reason: 'overdue');
    expect((w.inquiries.first.replied, w.inquiries.first.suppliers), (1, 2));
    expect(w.pending.single.lines, 2, reason: 'no line priced yet');
    expect(w.conflicts, 0);

    final msg = inquiryMessage(s, inq, supplierName: '乙机电', sender: '王工');
    expect(msg, startsWith('乙机电 您好'));
    expect(msg, contains('1. 离心泵 IS80，2 台'));
    expect(msg, contains('2. 闸阀 DN100，4 个'));
    expect(msg, contains('请在 2026-09-08 前回复'));
    expect(msg, endsWith('谢谢！王工'));
  });
}
