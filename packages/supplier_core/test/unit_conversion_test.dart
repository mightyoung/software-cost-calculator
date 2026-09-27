import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';
import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_units'));
  tearDown(() => tmp.deleteSync(recursive: true));
  test('combined rounding does not round tax before dividing units', () {
    expect(
      priceInUnit(
        {
          'price': '0.000001',
          'currency': 'CNY',
          'tax_mode': 'included',
          'tax_rate': '13',
          'unit_snapshot': '卷',
        },
        product: {
          'unit': '米',
          'unit_conversions': {'卷': '2'},
        },
        unit: '米',
        currency: 'CNY',
        taxMode: 'excluded',
      ),
      '0',
    );
  });
  test(
    'unit and tax normalize once; minimum and extras use target quantity',
    () {
      final s = device('A');
      addTearDown(s.close);
      final p = s.save('product', {
        ...product('线', unit: '米'),
        'unit_conversions': {'千米': '1000'},
      });
      final sup = s.save('supplier', supplier('甲'));
      final pro = s.save('project', project('P'));
      final q = s.save('quotation', {
        ...quotation(sup, p, pro, '1000'),
        'unit_snapshot': '千米',
        'min_qty': '0.001',
        'extra_cost': '10',
      });
      final option = s.quoteOptions(pro, p, qty: '1').single;
      expect(option.price, '1');
      expect(option.effectivePrice, '11');
      expect(option.meetsMinQty, isTrue);
      expect(
        s.quoteOptions(pro, p, qty: '0.999999').single.meetsMinQty,
        isFalse,
      );
      expect(s.get('quotation', q)!.data['price'], '1000');
      expect(s.compareQuotes(p).single.unit, '米');
      expect(s.compareQuotes(p).single.rows.single.comparisonPrice, '1');
      expect(
        s
            .priceHistory(p, currency: 'CNY', taxMode: 'included', unit: '米')!
            .average,
        '1',
      );
      for (final pair in [
        ['0.0005', '13', '0.000001'],
        ['0.000499', '0', '0'],
      ]) {
        expect(
          priceInUnit(
            {
              ...s.get('quotation', q)!.data,
              'price': pair[0],
              'tax_mode': 'excluded',
              'tax_rate': pair[1],
            },
            product: s.get('product', p)!.data,
            unit: '米',
            currency: 'CNY',
            taxMode: 'included',
          ),
          pair[2],
        );
      }
    },
  );
  test(
    'existing line unit survives refresh and award; snapshots stay fixed',
    () {
      final s = device('A');
      addTearDown(s.close);
      final p = s.save('product', {
        ...product('线', unit: '米'),
        'unit_conversions': {'千米': '1000'},
      });
      final sup = s.save('supplier', supplier('甲'));
      final pro = s.save('project', project('P'));
      final q = s.save('quotation', {
        ...quotation(sup, p, pro, '1'),
        'unit_snapshot': '米',
      });
      final line = s.save('project_item', {
        ...item(pro, 'material', productId: p),
        'unit': '千米',
      });
      expect(s.refreshPlan(pro).single.newCost, '1000');
      s.award(q, itemId: line);
      expect(s.get('project_item', line)!.data['unit_cost'], '1000');
      expect(s.get('project_item', line)!.data['unit'], '千米');
      expect(
        () => s.save('product', {
          ...s.get('product', p)!.data,
          'unit': '厘米',
        }, id: p),
        throwsFormatException,
      );
      s.save('product', {
        ...s.get('product', p)!.data,
        'unit_conversions': {'千米': '2000'},
      }, id: p);
      expect(s.get('project_item', line)!.data['unit_cost'], '1000');
      expect(s.refreshPlan(pro).single.newCost, '2000');
    },
  );
  test('changing a linked budget line unit requires a new converted cost', () {
    final s = device('A');
    addTearDown(s.close);
    final p = s.save('product', {
      ...product('线', unit: '米'),
      'unit_conversions': {'千米': '1000'},
    });
    final sup = s.save('supplier', supplier('甲'));
    final pro = s.save('project', project('P'));
    final q = s.save('quotation', {
      ...quotation(sup, p, pro, '1'),
      'unit_snapshot': '米',
    });
    final line = s.save('project_item', {
      ...item(pro, 'material', productId: p, quotationId: q, cost: '1'),
      'unit': '米',
    });
    final original = s.get('project_item', line)!.data;
    expect(
      () => s.save('project_item', {...original, 'unit': '千米'}, id: line),
      throwsFormatException,
    );
    expect(s.get('project_item', line)!.data['unit'], '米');
    s.save('project_item', {
      ...original,
      'unit': '千米',
      'unit_cost': '1000',
    }, id: line);
    expect(s.get('project_item', line)!.data['unit_cost'], '1000');
  });
  test('project copies retain historical converted costs', () {
    final s = device('A');
    addTearDown(s.close);
    final p = s.save('product', product('泵'));
    final sup = s.save('supplier', supplier('甲'));
    final pro = s.save('project', project('P'));
    final q = s.save('quotation', {
      ...quotation(sup, p, pro, '100'),
      'tax_mode': 'excluded',
    });
    s.save(
      'project_item',
      item(pro, 'material', productId: p, quotationId: q, cost: '113'),
    );
    s.save('quotation', {
      ...s.get('quotation', q)!.data,
      'price': '200',
    }, id: q);
    final copy = s.copyProject(pro, project('COPY'));
    expect(s.budget(copy).lines.single.data['unit_cost'], '113');
    expect(s.budget(copy).lines.single.data['quotation_id'], q);
    expect(
      () => s.copyProject(pro, project('USD', currency: 'USD')),
      throwsFormatException,
    );
  });
  test('unknown tax never labels an unconverted unit price as converted', () {
    final s = device('A');
    addTearDown(s.close);
    final p = s.save('product', {
      ...product('线', unit: '米'),
      'unit_conversions': {'千米': '1000'},
    });
    final sup = s.save('supplier', supplier('甲'));
    final pro = s.save('project', project('P'));
    s.save('quotation', {
      ...quotation(sup, p, pro, '1000'),
      'unit_snapshot': '千米',
      'tax_mode': 'unknown',
    });
    final group = s.compareQuotes(p).single;
    expect(group.unit, '千米');
    expect(group.rows.single.comparisonPrice, '1000');
    expect(group.rows.single.converted, isFalse);
  });
  test('cross-device unit and factor edits never splice a false basis', () {
    final a = device('A');
    final p = a.save('product', {
      ...product('线', unit: '米'),
      'unit_conversions': {'千米': '1000'},
    });
    final b = device('B', start: DateTime.utc(2026, 9, 2));
    addTearDown(a.close);
    addTearDown(b.close);
    b.importFrom(exported(a));
    a.save('product', {
      ...a.get('product', p)!.data,
      'unit': '厘米',
      'unit_conversions': null,
    }, id: p);
    b.save('product', {
      ...b.get('product', p)!.data,
      'unit_conversions': {'千米': '1000', '卷': '50'},
    }, id: p);
    a.importFrom(exported(b));
    b.importFrom(exported(a));
    expect(content(a), content(b));
    final merged = a.get('product', p)!.data;
    expect(
      [merged['unit'], merged['unit_conversions']],
      anyOf([
        ['厘米', null],
        [
          '米',
          {'千米': '1000', '卷': '50'},
        ],
      ]),
    );
  });
  test('cross-device unit and cost edits never splice a budget line', () {
    final a = device('A');
    final p = a.save('product', {
      ...product('线', unit: '米'),
      'unit_conversions': {'千米': '1000'},
    });
    final sup = a.save('supplier', supplier('甲'));
    final pro = a.save('project', project('P'));
    final q = a.save('quotation', {
      ...quotation(sup, p, pro, '1'),
      'unit_snapshot': '米',
    });
    final line = a.save('project_item', {
      ...item(pro, 'material', productId: p, quotationId: q, cost: '1'),
      'unit': '米',
    });
    final b = device('B', start: DateTime.utc(2026, 9, 2));
    addTearDown(a.close);
    addTearDown(b.close);
    b.importFrom(exported(a));
    a.save('project_item', {
      ...a.get('project_item', line)!.data,
      'unit': '千米',
      'qty': '0.001',
      'unit_cost': '1000',
    }, id: line);
    b.save('quotation', {...b.get('quotation', q)!.data, 'price': '2'}, id: q);
    b.save('project_item', {
      ...b.get('project_item', line)!.data,
      'unit_cost': '2',
    }, id: line);
    a.importFrom(exported(b));
    b.importFrom(exported(a));
    expect(content(a), content(b));
    final merged = a.get('project_item', line)!.data;
    // Unit, quantity and cost come from one device together.
    expect(
      [merged['unit'], merged['qty'], merged['unit_cost']],
      anyOf([
        ['千米', '0.001', '1000'],
        ['米', '1', '2'],
      ]),
    );
  });
  test('same-unit quantity and cost edits still merge independently', () {
    final a = device('A');
    final pro = a.save('project', project('P'));
    final line = a.save(
      'project_item',
      item(pro, 'labor', name: '安装', cost: '1'),
    );
    final b = device('B', start: DateTime.utc(2026, 9, 2));
    addTearDown(a.close);
    addTearDown(b.close);
    b.importFrom(exported(a));
    a.save('project_item', {
      ...a.get('project_item', line)!.data,
      'qty': '2',
    }, id: line);
    b.save('project_item', {
      ...b.get('project_item', line)!.data,
      'unit_cost': '3',
    }, id: line);
    a.importFrom(exported(b));
    expect(a.get('project_item', line)!.data['qty'], '2');
    expect(a.get('project_item', line)!.data['unit_cost'], '3');
  });
  test(
    'maps validate and synchronize both ways; old exchange upgrades untouched',
    () {
      final a = device('A'), b = device('B');
      addTearDown(a.close);
      addTearDown(b.close);
      for (final map in [
        {'千米': '0'},
        {'千米': '-1'},
        {'米': '1'},
        {'千米': '0.0000001'},
      ]) {
        expect(
          () => a.save('product', {
            ...product('线', unit: '米'),
            'unit_conversions': map,
          }),
          throwsFormatException,
        );
      }
      final p = a.save('product', product('线', unit: '米'));
      final old = exported(a);
      final db = sqlite3.open(old);
      db.execute(
        "UPDATE product SET data=json_remove(data, '\$.unit_conversions')",
      );
      db.execute("UPDATE meta SET value='5' WHERE key='schema_version'");
      db.close();
      final bytes = File(old).readAsBytesSync();
      b.importFrom(old);
      expect(b.get('product', p)!.data['unit_conversions'], isNull);
      expect(File(old).readAsBytesSync(), bytes);
      a.save('product', {
        ...a.get('product', p)!.data,
        'unit_conversions': {'千米': '1000.0'},
      }, id: p);
      b.importFrom(exported(a));
      expect(b.get('product', p)!.data['unit_conversions'], {'千米': '1000'});
      b.save('product', {
        ...b.get('product', p)!.data,
        'unit_conversions': {'千米': '1000', '卷': '50'},
      }, id: p);
      a.importFrom(exported(b));
      b.importFrom(exported(a));
      expect(a.get('product', p)!.data, b.get('product', p)!.data);
    },
  );
}
