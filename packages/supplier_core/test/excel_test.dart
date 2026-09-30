import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// A workbook shaped like Excel/WPS output: shared strings, a formula,
/// scientific notation and an explicit date system.
Uint8List officeLike(String cells, {bool date1904 = false}) {
  final files = {
    '[Content_Types].xml': '<Types/>',
    'xl/workbook.xml':
        '<workbook xmlns:r="r"><workbookPr date1904="${date1904 ? 1 : 0}"/>'
        '<sheets><sheet name="清单" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels':
        '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>',
    'xl/sharedStrings.xml':
        '<sst><si><t>离心水泵</t></si><si><r><t>000</t></r><r><t>123-A</t></r>'
        '<rPh><t>ignored</t></rPh></si></sst>',
    'xl/worksheets/sheet1.xml':
        '<worksheet><sheetData>$cells</sheetData></worksheet>',
  };
  final archive = Archive();
  for (final MapEntry(key: name, value: text) in files.entries) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_excel'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('written values read back exactly; money cells stay numeric', () {
    final bytes = writeXlsx([
      SheetData('表', [
        ['编号', '金额', '空'],
        ['000123-A', const Num('123456789012.123456'), null],
        ['13800000000', const Num('0.000001')],
      ]),
    ]);
    final rows = readXlsx(bytes).sheets.single.rows;
    expect(rows[1][0].text(), '000123-A');
    expect(rows[1][1].kind, CellKind.number);
    expect(rows[1][1].decimal(), '123456789012.123456');
    expect(rows[2][0].kind, CellKind.text, reason: 'phone stays text');
    expect(rows[2][1].decimal(), '0.000001');
    expect(rows[1].length, 2, reason: 'trailing blank not written');
  });

  test('office-style cells: shared strings, formulas, scientific, dates', () {
    final book = readXlsx(
      officeLike(
        '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c>'
        '<c r="C1"><v>1.38E+10</v></c><c r="D1"><f>C1*2</f><v>27600000000</v></c>'
        '<c r="F1"><v>45000</v></c><c r="G1"><v>60</v></c><c r="H1"><v>1.5</v></c>'
        '<c r="I1" t="e"><v>#N/A</v></c></row>',
      ),
    );
    final r = book.sheets.single.rows.single;
    expect(r[0].text(), '离心水泵');
    expect(
      r[1].text(),
      '000123-A',
      reason: 'rich text runs joined, phonetic dropped',
    );
    expect(r[2].text(), '13800000000');
    expect(r[3].display, '27600000000');
    expect(() => r[3].decimal(), throwsFormatException, reason: 'formula');
    expect(r[4].isBlank, isTrue, reason: 'E1 missing is blank');
    expect(r[5].date(date1904: false), '2023-03-15');
    expect(() => r[6].date(date1904: false), throwsFormatException);
    expect(() => r[7].date(date1904: false), throwsFormatException);
    expect(() => r[8].text(), throwsFormatException);
    // Files written by other tools may store a formula with an empty value.
    final noCache = readXlsx(
      officeLike('<row r="1"><c r="A1"><f>B1*2</f><v></v></c></row>'),
    );
    expect(workbookText(noCache), '【清单】');
    expect(
      () => noCache.sheets.single.rows.single.single.text(),
      throwsFormatException,
    );
    final mac = readXlsx(
      officeLike('<row r="1"><c r="A1"><v>43538</v></c></row>', date1904: true),
    );
    expect(mac.date1904, isTrue);
    expect(
      mac.sheets.single.rows.single.single.date(date1904: true),
      '2023-03-15',
    );
    expect(
      () => readXlsx(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });

  test('workbook text feeds the AI list flow', () {
    final text = workbookText(
      readXlsx(
        officeLike(
          '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>2</v></c></row>'
          '<row r="3"><c r="A3" t="inlineStr"><is><t>闸阀</t></is></c></row>',
        ),
      ),
    );
    expect(text, '【清单】\n离心水泵 | 2\n闸阀');
  });

  group('quotation template round trip', () {
    late Store s;
    late String sup, prod, pro, q1;
    setUp(() {
      s = device('A');
      sup = s.save('supplier', {
        ...supplier('甲泵业'),
        'aliases': ['甲'],
      });
      prod = s.save('product', {...product('离心水泵'), 'model': 'IS65'});
      pro = s.save('project', project('P-001'));
      q1 = s.save('quotation', quotation(sup, prod, pro, '100'));
    });

    Uint8List edited(List<List<Object?>> rows) => writeXlsx([
      SheetData('报价', [quoteColumns, ...rows]),
    ]);

    List<Object?> row({
      String? id,
      String? version,
      String? supplier = '甲',
      String price = '100',
      String date = '2026-09-01',
      String? notes,
    }) => [
      id,
      version,
      'P-001',
      supplier,
      '离心水泵',
      null,
      'IS65',
      null,
      null,
      Num(price),
      null,
      '含税',
      null,
      null,
      date,
      null,
      null,
      '李四',
      '2026-09-02',
      null,
      notes,
    ];

    test('update by ID, new rows, duplicates and errors are planned', () {
      final exported = readXlsx(s.exportQuotations(projectId: pro));
      expect(exported.sheets.single.rows[1][0].text(), q1);

      final plans = s.planQuotationImport(
        edited([
          row(id: q1, version: '1', price: '95.5', notes: '议价后'),
          row(price: '120', date: '2026-09-05'),
          row(),
          row(supplier: '不存在的公司'),
        ]),
      );
      expect(plans.map((p) => p.action), [
        RowAction.update,
        RowAction.create,
        RowAction.duplicate,
        RowAction.create,
      ]);
      expect(
        plans[0].changedFields,
        containsAll(['price', 'notes', 'inquirer_name']),
      );
      expect(plans[0].changedSinceExport, isFalse);
      expect(plans[3].newSupplier, '不存在的公司');
      expect(plans.map((p) => p.row), [2, 3, 4, 5]);

      expect(s.applyQuotationImport(plans), 3);
      expect(s.searchByName('supplier', '不存在的公司'), hasLength(1));
      expect(s.get('quotation', q1)!.data['price'], '95.5');
      expect(
        s.get('quotation', q1)!.data['tax_rate'],
        '13',
        reason: 'blank keeps',
      );

      // Re-importing the same file changes nothing.
      final again = s.planQuotationImport(
        edited([
          row(id: q1, version: '2', price: '95.5', notes: '议价后'),
          row(price: '120', date: '2026-09-05'),
        ]),
      );
      expect(again.map((p) => p.action), [
        RowAction.unchanged,
        RowAction.duplicate,
      ]);
    });

    test('a quote for a material not on file creates it, with its quoter', () {
      List<Object?> newRow(String? unit, {String phone = '13900000000'}) => [
        ...row(supplier: '乙阀门有限公司').take(4),
        '闸阀',
        '威乐',
        'Z41',
        'DN100',
        unit,
        Num('800'),
        ...row().skip(10).take(11),
        '王五',
        phone,
        '阀门',
      ];
      final plans = s.planQuotationImport(
        edited([newRow('个'), newRow('个', phone: '13700000000'), newRow(null)]),
      );
      expect(plans.map((p) => p.action), [
        RowAction.create,
        RowAction.create,
        RowAction.error,
      ]);
      expect(plans[2].error, contains('单位'));
      expect(s.applyQuotationImport(plans), 2);
      final valve = s.searchProducts(['闸阀']).single;
      expect(valve.data['category'], '阀门');
      expect(valve.data['unit'], '个');
      final supplierId = s.searchByName('supplier', '乙阀门').single.id;
      expect(s.contactsOf(supplierId), hasLength(2));
      final quotes = s.listQuotations(productId: valve.id);
      expect(quotes, hasLength(2));
      expect(
        quotes.map((q) => (q.data['contact_snapshot']! as Map)['name']),
        everyElement('王五'),
      );
      // The same supplier under its short name is not created again.
      final again = s.planQuotationImport(
        edited([
          [...newRow('个').take(3), '乙阀门', ...newRow('个').skip(4)],
        ]),
      );
      expect(again.single.newSupplier, isNull);
      expect(again.single.newProduct, isNull);
      expect(again.single.action, RowAction.duplicate);
    });

    test('a price sheet row without project or inquirer is historical', () {
      final r = row(price: '88', date: '2026-08-01');
      r[2] = null; // 项目编号
      r[17] = null; // 询价人
      r[18] = null; // 询价日期
      final plan = s.planQuotationImport(edited([r])).single;
      expect(plan.action, RowAction.create);
      expect(plan.payload!['capture_mode'], 'historical');
      expect(s.applyQuotationImport([plan]), 1);
      expect(
        s.listQuotations(productId: prod).map((q) => q.data['capture_mode']),
        contains('historical'),
      );
    });

    test('a record edited after export is flagged before overwrite', () {
      s.save('quotation', {
        ...quotation(sup, prod, pro, '100'),
        'notes': '本机改过',
      }, id: q1);
      final plans = s.planQuotationImport(
        edited([row(id: q1, version: '1', price: '90')]),
      );
      expect(plans.single.action, RowAction.update);
      expect(plans.single.changedSinceExport, isTrue);
    });
  });

  test(
    'project exports: customer sheet hides cost; inquiry list only unmatched',
    () {
      final s = device('A');
      final sup = s.save('supplier', supplier('甲泵业'));
      final prod = s.save('product', {...product('离心水泵'), 'model': 'IS65'});
      final pro = s.save(
        'project',
        project('P-001', contract: '1000', markup: '10'),
      );
      final q = s.save('quotation', quotation(sup, prod, pro, '100'));
      s.save(
        'project_item',
        item(
          pro,
          'material',
          productId: prod,
          quotationId: q,
          qty: '2',
          cost: '100',
        ),
      );
      s.save('project_item', {
        ...item(pro, 'material', name: '变频控制柜'),
        'notes': '要求：15kW',
      });
      s.save('project_item', item(pro, 'labor', name: '安装', cost: '50'));

      final quote = workbookText(readXlsx(s.exportQuoteSheet(pro)));
      expect(quote, contains('离心水泵 |  | IS65 |  | 件 | 2 | 110 | 220'));
      expect(quote, contains('合计 |  |  |  |  |  |  | 275'));
      expect(quote, isNot(contains('甲泵业')));

      final cost = workbookText(
        readXlsx(s.exportCostBudget(pro, asOf: DateTime.utc(2026, 9, 10))),
      );
      expect(cost, contains('甲泵业'));
      expect(cost, contains('材料费小计 |  |  |  |  |  |  |  | 200'));
      expect(cost, contains('待询价'));
      expect(cost, contains('成本合计 |  |  |  |  |  |  |  | 250'));

      final inquiry = readXlsx(s.exportInquiryList(pro)).sheets.single.rows;
      expect(inquiry.length, 5);
      expect(inquiry[4][1].text(), '变频控制柜');
      expect(inquiry[4][2].text(), '要求：15kW');
    },
  );
}
