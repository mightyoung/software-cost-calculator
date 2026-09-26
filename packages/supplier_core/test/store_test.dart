import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_core'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('edits bump versions and leave a field-level change log', () {
    final s = device('A');
    final id = s.save('supplier', supplier('甲'));
    s.save('supplier', {...supplier('甲公司'), 'notes': '常用'}, id: id);
    expect(s.get('supplier', id)!.version, 2);
    expect(s.changes(id).map((c) => [c['field'], c['old'], c['new']]), [
      ['(created)', null, null],
      ['name', '"甲"', '"甲公司"'],
      ['notes', 'null', '"常用"'],
    ]);
    s.delete('supplier', id);
    expect(s.get('supplier', id)!.deleted, isTrue);
    expect(
      () => s.save('supplier', supplier('x'), id: id),
      throwsFormatException,
    );
  });

  test(
    'standard quotations need a project; historical ones only via import',
    () {
      final s = device('A');
      final sup = s.save('supplier', supplier('甲'));
      final prod = s.save('product', product('螺栓'));
      expect(
        () => s.save('quotation', quotation(sup, prod, null, '1')),
        throwsFormatException,
      );
      final pro = s.save('project', project('P1'));
      s.save('quotation', quotation(sup, prod, pro, '1'));
      expect(
        () => s.save('quotation', {
          ...quotation(sup, prod, null, '1'),
          'capture_mode': 'historical',
        }),
        throwsFormatException,
      );
      expect(
        () => s.save('quotation', quotation(sup, newUuid(), pro, '1')),
        throwsFormatException,
        reason: 'unknown product reference',
      );
    },
  );

  test('import order does not matter and re-import changes nothing', () {
    final a = device('A'), b = device('B'), c = device('C');
    a.save('supplier', supplier('甲'));
    final shared = b.save('supplier', supplier('乙'));
    c.save('product', product('螺栓'));
    // B's record travels to C, which edits it later.
    c.importFrom(exported(b));
    c.save('supplier', supplier('乙公司'), id: shared);
    final files = [exported(a), exported(b), exported(c)];

    final x = device('X'), y = device('Y');
    for (final f in files) {
      x.importFrom(f);
    }
    for (final f in files.reversed) {
      y.importFrom(f);
    }
    expect(content(x), content(y));
    expect(x.get('supplier', shared)!.data['name'], '乙公司');

    final again = x.importFrom(files.last);
    expect(again.values.every((t) => t.added == 0 && t.updated == 0), isTrue);
    expect(content(x), content(y));
  });

  test('both sides editing the same version is reported; later edit wins', () {
    final a = device('A');
    final id = a.save('supplier', supplier('甲'));
    final b = device('B', start: DateTime.utc(2026, 9, 2));
    b.importFrom(exported(a));
    a.save('supplier', supplier('甲-A改'), id: id);
    b.save('supplier', supplier('甲-B改'), id: id); // later clock
    final fromB = exported(b);
    expect(a.previewImport(fromB)['supplier']!.conflicts, [id]);
    a.importFrom(fromB);
    b.importFrom(exported(a));
    expect(a.get('supplier', id)!.data['name'], '甲-B改');
    expect(content(a), content(b));
  });

  test('damaged, foreign or tampered files are rejected without changes', () {
    final a = device('A');
    a.save('supplier', supplier('甲'));
    final before = content(a);

    final junk = File('${tmp.path}/junk.siq')..writeAsBytesSync([1, 2, 3, 4]);
    expect(() => a.importFrom(junk.path), throwsA(anything));

    final other = device('B');
    other.save('supplier', supplier('乙'));
    final tampered = exported(other);
    final t = Store.open(tampered, device: 'T');
    t.db.execute("UPDATE supplier SET data = replace(data, '乙', ' 乙 ')");
    t.close();
    expect(() => a.importFrom(tampered), throwsFormatException);

    final dangling = device('C');
    final sup = dangling.save('supplier', supplier('丙'));
    final pro = dangling.save('project', project('P'));
    final prod = dangling.save('product', product('螺栓'));
    dangling.save('quotation', quotation(sup, prod, pro, '1'));
    dangling.db.execute("DELETE FROM product");
    expect(() => a.importFrom(exported(dangling)), throwsFormatException);

    expect(content(a), before);
  });

  group('budget', () {
    late Store s;
    late String sup, prod, pro;
    final asOf = DateTime.utc(2026, 9, 10);
    setUp(() {
      s = device('A');
      sup = s.save('supplier', supplier('甲'));
      prod = s.save('product', product('螺栓'));
      pro = s.save('project', project('P1', contract: '100', markup: '12.5'));
    });

    test('totals are exact and grouped by category with markup', () {
      s.save(
        'project_item',
        item(pro, 'material', productId: prod, qty: '3', cost: '0.1'),
      );
      s.save(
        'project_item',
        item(pro, 'labor', name: '安装', qty: '2', cost: '10.333333'),
      );
      s.save(
        'project_item',
        item(pro, 'other', name: '运费', cost: '5', price: '6'),
      );
      final b = s.budget(pro, asOf: asOf);
      expect(b.costByCategory, {
        'material': '0.3',
        'labor': '20.666666',
        'other': '5',
      });
      expect(b.cost, '25.966666');
      // 0.1 * 1.125 = 0.1125; 10.333333 * 1.125 = 11.624999625 -> 11.625
      expect(b.lines.map((l) => l.unitPrice), ['0.1125', '11.625', '6']);
      expect(b.price, '29.5875');
      expect(b.margin, '3.620834');
      expect(b.contractWarning, isFalse);
    });

    test('contract warning starts at exactly 90 percent', () {
      final line = s.save(
        'project_item',
        item(pro, 'other', name: 'x', cost: '89.999999'),
      );
      expect(s.budget(pro).contractWarning, isFalse);
      s.save(
        'project_item',
        item(pro, 'other', name: 'x', cost: '90'),
        id: line,
      );
      expect(s.budget(pro).contractWarning, isTrue);
    });

    test('lowest valid quote first; undated validity lasts 90 days', () {
      final old = s.save(
        'quotation',
        quotation(sup, prod, pro, '1', quotedOn: '2026-06-12'),
      );
      final expired = s.save(
        'quotation',
        quotation(
          sup,
          prod,
          pro,
          '2',
          quotedOn: '2026-09-01',
          validUntil: '2026-09-09',
        ),
      );
      final ok = s.save('quotation', quotation(sup, prod, pro, '3'));
      s.save('quotation', quotation(sup, prod, pro, '0.5', currency: 'USD'));
      final options = s.quoteOptions(pro, prod, asOf: asOf);
      expect(options.map((o) => o.id), [old, ok, expired]);
      expect(options.map((o) => o.valid), [true, true, false]);
      expect(options.first.validityPending, isTrue);
      // Quoted exactly 90 days before asOf: still valid; one day later it is not.
      final nextDay = asOf.add(const Duration(days: 1));
      expect(s.quoteOptions(pro, prod, asOf: nextDay).first.id, ok);
    });

    test(
      'snapshot price stays; cheaper quote beyond 10 percent only warns',
      () {
        final q = s.save('quotation', quotation(sup, prod, pro, '100'));
        final line = s.save(
          'project_item',
          item(pro, 'material', productId: prod, quotationId: q, cost: '100'),
        );
        s.save('quotation', quotation(sup, prod, pro, '90'));
        expect(s.budget(pro, asOf: asOf).lines.single.warnings, isEmpty);
        s.save('quotation', quotation(sup, prod, pro, '89.99'));
        final b = s.budget(pro, asOf: asOf);
        expect(b.lines.single.warnings, ['cheaper_available']);
        expect(s.get('project_item', line)!.data['unit_cost'], '100');
        s.delete('quotation', q);
        expect(s.budget(pro, asOf: asOf).lines.single.warnings, [
          'cheaper_available',
          'quote_not_valid',
        ]);
      },
    );

    test(
      'a quote whose minimum order exceeds the line quantity is not used',
      () {
        final bulk = s.save('quotation', {
          ...quotation(sup, prod, pro, '80'),
          'min_qty': '100',
        });
        final small = s.save('quotation', quotation(sup, prod, pro, '95'));
        // Quantity unknown: minimum order cannot be judged.
        expect(s.quoteOptions(pro, prod, asOf: asOf).first.id, bulk);
        final two = s.quoteOptions(pro, prod, asOf: asOf, qty: '2');
        expect(two.map((o) => o.id), [small, bulk]);
        expect(two.last.valid, isFalse);
        expect(two.last.meetsMinQty, isFalse);
        expect(two.last.dateValid, isTrue);
        expect(
          s.quoteOptions(pro, prod, asOf: asOf, qty: '100').first.id,
          bulk,
        );
        final tool =
            jsonDecode(
                  s.runTool(
                    'quote_options',
                    jsonEncode({'product_id': prod, 'qty': 2}),
                  ),
                )
                as List;
        expect(tool.first['id'], small);
        expect(tool.last['meets_min_qty'], isFalse);

        // The bulk price must not raise "cheaper available" for 2 units.
        final line = s.save(
          'project_item',
          item(pro, 'material', productId: prod, quotationId: small, cost: '95')
            ..['qty'] = '2',
        );
        expect(s.budget(pro, asOf: asOf).lines.single.warnings, isEmpty);
        // Linking the bulk quote to 2 units is flagged as below minimum order.
        s.save(
          'project_item',
          item(pro, 'material', productId: prod, quotationId: bulk, cost: '80')
            ..['qty'] = '2',
          id: line,
        );
        expect(s.budget(pro, asOf: asOf).lines.single.warnings, [
          'below_min_qty',
        ]);
        s.save(
          'project_item',
          item(pro, 'material', productId: prod, quotationId: bulk, cost: '80')
            ..['qty'] = '100',
          id: line,
        );
        expect(s.budget(pro, asOf: asOf).lines.single.warnings, isEmpty);
      },
    );

    test('quote in another currency cannot price a line', () {
      final usd = s.save(
        'quotation',
        quotation(sup, prod, pro, '1', currency: 'USD'),
      );
      expect(
        () => s.save(
          'project_item',
          item(pro, 'material', productId: prod, quotationId: usd, cost: '1'),
        ),
        throwsFormatException,
      );
    });

    test('copying a project copies its lines and survives exchange', () {
      s.save(
        'project_item',
        item(pro, 'material', productId: prod, qty: '2', cost: '3'),
      );
      s.save('project_item', item(pro, 'labor', name: '安装', cost: '4'));
      final copy = s.copyProject(pro, project('P2', markup: '12.5'));
      expect(s.budget(copy).cost, '10');
      final other = device('B');
      other.importFrom(exported(s));
      expect(other.budget(copy).cost, s.budget(copy).cost);
      expect(other.budget(copy).price, s.budget(copy).price);
    });
  });
}
