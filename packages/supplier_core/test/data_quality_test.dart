import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_quality'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('counts records and the gaps that need attention', () {
    final s = device('A');
    Map<String, int> issues() => {
      for (final c in s.dataQuality()) c.key: c.count,
    };
    expect(issues().values, everyElement(0), reason: 'empty database');

    final jia = s.save('supplier', supplier('上海甲泵业有限公司'));
    s.save('supplier', {
      ...supplier('甲泵业'),
      'aliases': ['上海甲泵业'],
    });
    final yi = s.save('supplier', supplier('乙机电'));
    s.save('contact', {
      'supplier_id': yi,
      'name': '李',
      'phone': '1',
      'wechat': null,
      'email': null,
      'notes': null,
    });
    final pump = s.save('product', {...product('泵'), 'model': 'CR10-5'});
    final twin = s.save('product', {...product('立式泵'), 'model': 'cr 10－5'});
    s.save('product', {
      ...product('泵'),
      'model': 'CR10-5',
      'brand': '别家',
    }); // other brand: not the same material
    final pro = s.save('project', project('P1'));
    s.save('project_item', item(pro, 'material', name: '变频柜'));
    s.save('quotation', {
      ...quotation(jia, pump, pro, '1'),
      'tax_mode': 'unknown',
    });
    // Undated quotes only arrive as imported historical records.
    final old = s.save('quotation', quotation(yi, pump, pro, '2'));
    s.db.execute(
      "UPDATE quotation SET data = json_set(data, '\$.quoted_on', NULL) "
      'WHERE id = ?',
      [old],
    );

    expect(issues(), {
      'open_conflicts': 0,
      'duplicate_suppliers': 1,
      'duplicate_products': 1,
      'unknown_tax_mode': 1,
      'undated_quotes': 1,
      'needs_inquiry': 1,
      'spec_clauses_unreviewed': 0,
      'spec_items_unchosen': 0,
      'products_never_quoted': 2,
      'products_unclassified': 0,
      'products_missing_key_params': 0,
      'products_unconfirmed_params': 0,
      'suppliers_without_contact': 2,
    });
    s.mergeInto('product', twin, pump);
    expect(issues()['duplicate_products'], 0);
    expect(s.recordCounts(), {
      'supplier': 3,
      'contact': 1,
      'product': 2,
      'project': 1,
      'quotation': 2,
      'project_item': 1,
      'inquiry': 0,
      'product_param': 0,
      'spec_request': 0,
      'spec_item': 0,
      'spec_response': 0,
    });
    expect(agentGuide(), contains('data_quality('));
  });

  test('technical requirements: unchecked clauses and unchosen items', () {
    final s = device('A');
    Map<String, int> issues() => {
      for (final c in s.dataQuality())
        if (c.area == QualityArea.requirements) c.key: c.count,
    };
    final req = s.createSpecRequest('泵房', [
      draftItem('温湿度传感器', '测量范围-20~80℃；防护等级不低于IP65'),
    ]);
    expect(issues()['spec_clauses_unreviewed'], 2);
    expect(issues()['spec_items_unchosen'], 1);
    s.deleteSpecRequest(req);
    expect(issues()['spec_clauses_unreviewed'], 0);
    expect(issues()['spec_items_unchosen'], 0);
  });
}
