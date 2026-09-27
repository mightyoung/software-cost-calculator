import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_trash'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('deleted records wait in the bin and come back as they were', () {
    final s = device('A');
    final sup = s.save('supplier', supplier('甲泵业'));
    final pump = s.save('product', product('泵'));
    final pro = s.save('project', project('P1'));
    s.save('quotation', quotation(sup, pump, pro, '10'));
    s.save('contact', {
      'supplier_id': sup,
      'name': '张三',
      'phone': '1',
      'wechat': null,
      'email': null,
      'notes': null,
    });
    expect(s.referencesTo('supplier', sup), {
      'contact.supplier_id': 1,
      'quotation.supplier_id': 1,
    });
    expect(describeReferences(s.referencesTo('supplier', sup)), '1 条联系人、1 条报价');

    s.delete('supplier', sup);
    final bin = s.deletedRecords();
    expect(bin.single.id, sup);
    expect(bin.single.data['name'], '甲泵业');
    expect(s.searchByName('supplier', '甲泵'), isEmpty);

    s.restore('supplier', sup);
    expect(s.get('supplier', sup)!.deleted, isFalse);
    expect(s.deletedRecords(), isEmpty);
    expect(s.searchByName('supplier', '甲泵').single.id, sup);
    expect(() => s.restore('supplier', sup), throwsFormatException);
  });

  test('a restore reaches devices that already received the delete', () {
    final a = device('A');
    final id = a.save('supplier', supplier('甲'));
    final b = device('B', start: DateTime.utc(2026, 9, 1, 0, 30));
    b.importFrom(exported(a));
    a.delete('supplier', id);
    b.importFrom(exported(a));
    expect(b.get('supplier', id)!.deleted, isTrue);
    a.restore('supplier', id);
    b.importFrom(exported(a));
    expect(b.get('supplier', id)!.deleted, isFalse);
    a.importFrom(exported(b));
    expect(content(a), content(b));
  });

  test('an edit racing a delete does not undo it; a later restore does', () {
    final a = device('A');
    final id = a.save('supplier', supplier('甲'));
    final b = device('B', start: DateTime.utc(2026, 9, 1, 0, 30));
    b.importFrom(exported(a));
    a.delete('supplier', id);
    b.save('supplier', {...supplier('甲'), 'notes': '还在用'}, id: id);
    a.importFrom(exported(b));
    b.importFrom(exported(a));
    expect(a.get('supplier', id)!.deleted, isTrue);
    expect(b.get('supplier', id)!.deleted, isTrue);
    b.restore('supplier', id);
    a.importFrom(exported(b));
    expect(a.get('supplier', id)!.deleted, isFalse);
    expect(a.get('supplier', id)!.data['notes'], '还在用');
    b.importFrom(exported(a));
    expect(content(a), content(b));
  });
}
