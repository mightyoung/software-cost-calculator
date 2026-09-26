import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_v3'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('scope and award fields are validated and canonical', () {
    final s = device('A');
    final sup = s.save('supplier', supplier('甲'));
    final prod = s.save('product', product('泵'));
    final pro = s.save('project', project('P1'));
    final q = s.save('quotation', {
      ...quotation(sup, prod, pro, '100'),
      'includes': ['training', 'freight', 'freight'],
      'warranty_months': 12,
      'extra_cost': '500.00',
    });
    final data = s.get('quotation', q)!.data;
    expect(data['includes'], ['freight', 'training']);
    expect(data['extra_cost'], '500');
    expect(
      () => s.save('quotation', {
        ...data,
        'includes': ['lunch'],
      }, id: q),
      throwsFormatException,
    );
    expect(
      () => s.save('quotation', {...data, 'awarded_on': '2026-09-02'}, id: q),
      throwsFormatException,
      reason: 'an award needs the agreed price',
    );
    s.save('quotation', {
      ...data,
      'awarded_on': '2026-09-02',
      'deal_price': '92',
    }, id: q);
    expect(s.get('quotation', q)!.data['deal_price'], '92');
  });

  test('attachments travel with the exchange file', () {
    final a = device('A');
    final sup = a.save('supplier', supplier('甲'));
    final prod = a.save('product', product('泵'));
    final pro = a.save('project', project('P1'));
    final att = a.addAttachment('报价单.txt', utf8.encode('IS80 单价 3200'));
    a.save('quotation', {
      ...quotation(sup, prod, pro, '3200'),
      'attachment_ids': [att],
    });
    expect(
      () => a.save('quotation', {
        ...quotation(sup, prod, pro, '1'),
        'attachment_ids': [newUuid()],
      }),
      throwsFormatException,
    );

    final b = device('B');
    b.importFrom(exported(a));
    expect(utf8.decode(b.attachment(att)!.bytes!), 'IS80 单价 3200');
    b.importFrom(exported(a));
    expect(b.attachmentsOf([att]).single.name, '报价单.txt');

    final tampered = exported(a);
    final db = sqlite3.open(tampered);
    db.execute('UPDATE attachment SET size = size + 1');
    db.close();
    expect(() => device('C').importFrom(tampered), throwsFormatException);
  });

  test('inquiries check their lists and follow supplier merges', () {
    final s = device('A');
    final keep = s.save('supplier', supplier('甲'));
    final dup = s.save('supplier', supplier('甲公司'));
    final pro = s.save('project', project('P1'));
    final line = s.save('project_item', item(pro, 'material', name: '闸阀'));
    Map<String, Object?> inquiry(List<String> suppliers) => {
      'project_id': pro,
      'title': '阀门询价',
      'item_ids': [line],
      'supplier_ids': suppliers,
      'due_date': null,
      'status': 'open',
      'notes': null,
    };
    expect(
      () => s.save('inquiry', inquiry([newUuid()])),
      throwsFormatException,
    );
    final id = s.save('inquiry', inquiry([keep, dup]));
    s.mergeInto('supplier', dup, keep);
    expect(s.get('inquiry', id)!.data['supplier_ids'], [keep]);
  });
}
