import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_merge'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('merging moves references and hides the duplicate', () {
    final s = device('A');
    final keep = s.save('supplier', supplier('甲泵业'));
    final dup = s.save('supplier', {
      ...supplier('上海甲泵业有限公司'),
      'aliases': ['甲泵'],
    });
    final cid = s.save('contact', {
      'supplier_id': dup,
      'name': '张三',
      'phone': '1',
      'wechat': null,
      'email': null,
      'notes': null,
    });
    final pump = s.save('product', {...product('泵'), 'model': 'CR10-5'});
    final pumpDup = s.save('product', {...product('多级泵'), 'model': 'CR 10-5'});
    final pro = s.save('project', project('P1'));
    final q = s.save('quotation', {
      ...quotation(dup, pumpDup, pro, '100'),
      'contact_id': cid,
      'contact_snapshot': {
        'name': '张三',
        'phone': '1',
        'wechat': null,
        'email': null,
      },
    });
    final line = s.save(
      'project_item',
      item(pro, 'material', productId: pumpDup, quotationId: q, cost: '100'),
    );

    s.mergeInto('supplier', dup, keep);
    s.mergeInto('product', pumpDup, pump);

    expect(s.get('supplier', dup)!.data['merged_into'], keep);
    expect(s.get('supplier', keep)!.data['aliases'], ['上海甲泵业有限公司', '甲泵']);
    expect(s.get('contact', cid)!.data['supplier_id'], keep);
    expect(s.get('quotation', q)!.data['supplier_id'], keep);
    expect(s.get('quotation', q)!.data['product_id'], pump);
    expect(s.get('project_item', line)!.data['product_id'], pump);
    expect(s.searchByName('supplier', '甲泵').map((h) => h.id), [keep]);
    expect(s.searchProducts(['泵']).map((h) => h.id), [pump]);
    expect(s.compareQuotes(pump).single.rows.single.issues, isEmpty);

    expect(() => s.mergeInto('supplier', keep, keep), throwsFormatException);
    expect(
      () => s.mergeInto('supplier', keep, dup),
      throwsFormatException,
      reason: 'dup already resolves to keep',
    );
    expect(() => s.mergeInto('project', pro, pro), throwsFormatException);
  });

  test('merge roots converge through chains and cycles longer than 64', () {
    final s = device('A');
    addTearDown(s.close);
    final ids = [
      for (var i = 0; i < 70; i++) s.save('supplier', supplier('供应商$i')),
    ];
    for (var i = 0; i < ids.length - 1; i++) {
      s.save('supplier', {
        ...s.get('supplier', ids[i])!.data,
        'merged_into': ids[i + 1],
      }, id: ids[i]);
    }
    expect(s.mergeRoot('supplier', ids.first), ids.last);
    s.save('supplier', {
      ...s.get('supplier', ids.last)!.data,
      'merged_into': ids.first,
    }, id: ids.last);
    final root = (ids.toList()..sort()).first;
    for (final id in ids) {
      expect(s.mergeRoot('supplier', id), root);
    }
    s.redirectMerged();
    for (final id in ids) {
      expect(s.mergeRoot('supplier', id), root);
    }
    expect(s.redirectMerged(), 0);
  });

  test('references made elsewhere follow a merge; devices converge', () {
    final a = device('A');
    final keep = a.save('supplier', supplier('甲泵业'));
    final dup = a.save('supplier', supplier('甲泵业（重复）'));
    final prod = a.save('product', product('泵'));
    final pro = a.save('project', project('P1'));
    final b = device('B', start: DateTime.utc(2026, 9, 2));
    b.importFrom(exported(a));

    // B quotes the duplicate before hearing about the merge.
    final q = b.save('quotation', quotation(dup, prod, pro, '90'));
    a.mergeInto('supplier', dup, keep);

    a.importFrom(exported(b));
    expect(a.get('quotation', q)!.data['supplier_id'], keep);
    b.importFrom(exported(a));
    expect(b.get('quotation', q)!.data['supplier_id'], keep);
    a.importFrom(exported(b));
    b.importFrom(exported(a));
    expect(content(a), content(b));
  });

  test('opposite merges on two devices resolve to one record', () {
    final a = device('A');
    final x = a.save('supplier', supplier('X'));
    final y = a.save('supplier', supplier('Y'));
    final prod = a.save('product', product('泵'));
    final pro = a.save('project', project('P1'));
    final q = a.save('quotation', quotation(x, prod, pro, '1'));
    final b = device('B', start: DateTime.utc(2026, 9, 2));
    b.importFrom(exported(a));

    a.mergeInto('supplier', x, y);
    b.mergeInto('supplier', y, x);
    a.importFrom(exported(b));
    b.importFrom(exported(a));
    a.importFrom(exported(b));
    expect(content(a), content(b));

    final roots = [
      for (final id in [x, y])
        if (a.get('supplier', id)!.data['merged_into'] == null) id,
    ];
    expect(roots, hasLength(1));
    expect(a.mergeRoot('supplier', x), roots.single);
    expect(a.mergeRoot('supplier', y), roots.single);
    expect(a.get('quotation', q)!.data['supplier_id'], roots.single);
  });

  test('a merge into a record deleted elsewhere is undone', () {
    final a = device('A');
    final x = a.save('supplier', supplier('X'));
    final y = a.save('supplier', supplier('Y'));
    final prod = a.save('product', product('泵'));
    final pro = a.save('project', project('P1'));
    final q = a.save('quotation', quotation(x, prod, pro, '1'));
    final b = device('B', start: DateTime.utc(2026, 9, 2));
    b.importFrom(exported(a));

    a.mergeInto('supplier', x, y);
    b.delete('supplier', y);
    a.importFrom(exported(b));
    b.importFrom(exported(a));
    a.importFrom(exported(b));
    expect(content(a), content(b));
    expect(a.get('supplier', x)!.data['merged_into'], isNull);
    expect(a.searchByName('supplier', 'X').map((h) => h.id), [x]);
    expect(a.get('quotation', q)!.data['supplier_id'], anyOf(x, y));
  });
}
