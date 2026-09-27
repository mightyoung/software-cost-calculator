import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_refresh'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('refresh previews better prices, then applies the chosen lines', () {
    final s = device('A');
    final sup = s.save('supplier', supplier('甲'));
    final pump = s.save('product', product('泵'));
    final valve = s.save('product', product('阀'));
    final pro = s.save('project', project('P1'));
    final old = s.save('quotation', quotation(sup, pump, pro, '100'));
    final pumpLine = s.save(
      'project_item',
      item(
        pro,
        'material',
        productId: pump,
        quotationId: old,
        cost: '100',
        qty: '10', // 95 + 20 / 10 = 97 beats 100
      ),
    );
    final valveLine = s.save(
      'project_item',
      item(pro, 'material', productId: valve, cost: '50'),
    );
    s.save('project_item', item(pro, 'labor', name: '安装', cost: '10'));
    final newer = s.save('quotation', {
      ...quotation(sup, pump, pro, '95'),
      'extra_cost': '20',
    });
    final valveQuote = s.save('quotation', quotation(sup, valve, pro, '48'));

    final plan = s.refreshPlan(pro, asOf: DateTime.utc(2026, 9, 10));
    expect(plan.map((l) => l.itemId), [pumpLine, valveLine]);
    final p = plan.first;
    expect((p.currentCost, p.newCost, p.option.id), ('100', '95', newer));
    expect(p.manual, isFalse);
    expect(plan.last.manual, isTrue, reason: 'hand-entered estimate');

    s.applyRefresh([p]);
    final line = s.get('project_item', pumpLine)!.data;
    expect(line['quotation_id'], newer);
    expect(line['unit_cost'], '95');
    expect(line['notes'], contains('附加费用 20'));
    expect(s.get('project_item', valveLine)!.data['unit_cost'], '50');
    expect(
      s.refreshPlan(pro, asOf: DateTime.utc(2026, 9, 10)).single.option.id,
      valveQuote,
    );
  });
}
