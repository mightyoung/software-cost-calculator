import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';
import 'sheet_text_security_test.dart' show continuationWorkbook;

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_sheet'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test(
    'supplier planning rejects repeated shared whitespace before scanning',
    () {
      final s = device('A');
      addTearDown(s.close);
      final bytes = continuationWorkbook(' ' * 32767, 33);
      expect(bytes.length, lessThan(10000));
      final book = readXlsx(bytes);
      expect(() => s.planSupplierSheet(book), throwsFormatException);
      expect(s.searchByName('supplier', ''), isEmpty);
    },
  );

  test('supplier text guard covers headers and ignored columns', () {
    final s = device('A');
    addTearDown(s.close);
    for (final rows in [
      [
        [XCell('A1', CellKind.text, ' ' * 65537)],
      ],
      [
        [const XCell('A1', CellKind.text, '供应商名称')],
        [
          const XCell('A2', CellKind.text, '甲'),
          XCell('B2', CellKind.text, ' ' * 65537),
        ],
      ],
    ]) {
      expect(
        () => s.planSupplierSheet(
          XWorkbook([XSheet('S', rows)], date1904: false),
        ),
        throwsFormatException,
      );
    }
  });

  test('supplier aggregate text guard spans headerless sheets', () {
    final s = device('A');
    addTearDown(s.close);
    final shared = ' ' * 32767;
    final book = XWorkbook([
      for (var sheet = 0; sheet < 3; sheet++)
        XSheet('S$sheet', [
          for (var row = 0; row < 11; row++)
            [XCell('A${row + 1}', CellKind.text, shared)],
        ]),
    ], date1904: false);
    expect(() => s.planSupplierSheet(book), throwsFormatException);
  });

  test('rows pasted from Excel read like a sheet, quoted cells included', () {
    const pasted =
        '设备名称\t品牌\t型号\t主要指标要求\t单位\t数量\t单价\r\n'
        '网关\t巨控\tNET422-CS\t"支持 Modbus\n支持 OPC ""UA"""\t个\t4\t3,190\r\n'
        '显示器\tAOC\tQ27G40HE\t\t个\t7\t879\r\n';
    final offers = offersFromWorkbook(tableFromText(pasted)!)!;
    expect(offers, hasLength(2));
    expect(offers[0]['specification'], '支持 Modbus\n支持 OPC "UA"');
    expect(offers[0]['price'], '3190');
    expect(offers[1]['supplier'], 'AOC');
    expect(tableFromText('一段没有制表符的文字'), isNull);
  });

  test('a material list imports without a project: no quotations', () {
    final s = device('A');
    final offers = offersFromWorkbook(
      tableFromText('名称\t品牌\t型号\t单位\t单价\n网关\t巨控\tNET422\t个\t3190\n')!,
    )!;
    final p = s.planOffer(offers.single);
    final sum = s.applyOffers(
      [(offer: p.offer, supplierId: p.supplierId, productId: p.productId)],
      projectId: null,
      inquirer: '王五',
    );
    expect((sum.suppliers, sum.products, sum.quotations), (1, 1, 0));
  });

  test('supplier list: new, existing with a new contact, repeats, errors', () {
    final s = device('A');
    final known = s.save('supplier', supplier('甲泵业有限公司'));
    const list =
        '供应商名称\t联系人\t电话\t类别\t地址\n'
        '甲泵业有限公司\t张三\t13800000000\t泵\t\n'
        '乙阀门\t李四\t微信联系\t阀门、管件\t上海\n'
        '乙阀门\t王五\t13900000000\t\t\n'
        '\t赵六\t13700000000\t\t\n';
    final plans = s.planSupplierSheet(tableFromText(list)!)!;
    expect([for (final p in plans) p.error], [null, null, null, '缺少供应商名称']);
    expect(plans[0].existingId, known);
    expect(plans[1].supplier!['categories'], ['阀门', '管件']);
    expect(plans[1].contact, isNull, reason: '"微信联系" is no phone');
    expect(plans[2].supplier, isNull, reason: 'repeated name');

    final sum = s.applySupplierSheet(plans);
    expect(sum, (suppliers: 1, contacts: 2));
    final yi = s.searchByName('supplier', '乙阀门').single;
    expect(s.contactsOf(yi.id).single.data['name'], '王五');
    // Importing the same list again adds nothing.
    final again = s.planSupplierSheet(tableFromText(list)!)!;
    expect(s.applySupplierSheet(again), (suppliers: 0, contacts: 0));
  });
}
