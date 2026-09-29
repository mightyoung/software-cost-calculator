import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  late Store s;
  late String sup, prod, pro;
  Object? run(String name, Map<String, Object?> args) =>
      jsonDecode(s.runTool(name, jsonEncode(args)));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('agent_query');
    s = device('A');
    sup = s.save('supplier', supplier('甲'));
    prod = s.save('product', product('泵'));
    pro = s.save('project', project('P1'));
  });
  tearDown(() {
    s.close();
    tmp.deleteSync(recursive: true);
  });

  test('boolean eq, ne and in use JSON booleans', () {
    for (final confirmed in [true, false]) {
      s.save('product_param', {
        'product_id': prod,
        'property': confirmed ? 'cpu.cores' : 'memory.capacity',
        'value': {'v': '8'},
        'cond': null,
        'source': 'manual',
        'evidence': null,
        'attachment_id': null,
        'confirmed': confirmed,
        'dict_version': 1,
      });
    }
    for (final (op, value, expected) in [
      ('eq', true, true),
      ('eq', false, false),
      ('ne', true, false),
      ('in', [true], true),
    ]) {
      final result = s.queryRecords(
        'product_param',
        where: [
          {'field': 'confirmed', 'op': op, 'value': value},
        ],
      );
      expect(result.total, 1);
      expect(result.rows.single['confirmed'], expected);
    }
    expect(
      run('query', {
        'type': 'product_param',
        'where': [
          {'field': 'confirmed', 'op': 'eq', 'value': 'true'},
        ],
      }),
      containsPair('error', isNotNull),
    );
  });

  test('decimal comparison preserves the last digit at maximum precision', () {
    const prices = ['999999999999.999998', '999999999999.999999'];
    for (final price in prices) {
      s.save('quotation', quotation(sup, prod, pro, price));
    }
    for (final op in ['eq', 'gte', 'gt', 'in']) {
      final value = op == 'gt' ? prices.first : prices.last;
      final r = s.queryRecords(
        'quotation',
        where: [
          {
            'field': 'price',
            'op': op,
            'value': op == 'in' ? [value] : value,
          },
        ],
      );
      expect(r.total, 1, reason: op);
      expect(r.rows.single['price'], prices.last);
    }
    expect(
      s.queryRecords('quotation', orderBy: 'price').rows.map((r) => r['price']),
      prices,
    );
  });

  test('query and related page through all rows with stable tied ordering', () {
    for (var i = 0; i < 53; i++) {
      s.save('quotation', quotation(sup, prod, pro, '1'));
    }
    for (final tool in ['query', 'related']) {
      final args = tool == 'query'
          ? <String, Object?>{'type': 'quotation', 'order_by': 'price'}
          : <String, Object?>{'link': 'quotation.supplier_id', 'id': sup};
      final first = run(tool, {...args, 'limit': 50}) as Map;
      expect(first['total'], 53);
      expect(first['returned'], 50);
      expect(first['offset'], 0);
      expect(first['has_more'], true);
      expect(first['next_offset'], 50);
      final second =
          run(tool, {
                ...args,
                'limit': 50,
                'offset': 50,
                'snapshot': first['snapshot'],
              })
              as Map;
      expect(second['returned'], 3);
      expect(second['has_more'], false);
      expect(second['next_offset'], isNull);
      final beyond =
          run(tool, {...args, 'offset': 100, 'snapshot': first['snapshot']})
              as Map;
      expect(beyond['rows'], isEmpty);
      expect(beyond['total'], 53);
      expect(beyond['has_more'], false);
      expect({
        ...[...first['rows'], ...second['rows']].map((r) => r['id']),
      }, hasLength(53));
      for (final offset in [-1, 0.5, '1']) {
        expect(
          run(tool, {...args, 'offset': offset}),
          containsPair('error', isNotNull),
        );
      }
    }
    expect(
      () => s.queryRecords('quotation', offset: -1),
      throwsFormatException,
    );
    expect(
      () => s.relatedRecords('quotation.supplier_id', sup, offset: -1),
      throwsFormatException,
    );
    expect(() => s.queryRecords('quotation', limit: 0), throwsFormatException);
  });

  test('invalid supplied quantity is an error, not omitted demand', () {
    for (final qty in ['bad', '', '0', '-1', '1.0000001']) {
      expect(
        run('quote_options', {
          'project_id': pro,
          'product_id': prod,
          'qty': qty,
        }),
        containsPair('error', isNotNull),
        reason: qty,
      );
    }
  });

  test('pagination rejects writes that move unseen rows before the offset', () {
    final older = s.save('quotation', quotation(sup, prod, pro, '1'));
    s.save('quotation', quotation(sup, prod, pro, '2'));
    for (final external in [false, true]) {
      final first = run('query', {'type': 'quotation', 'limit': 1}) as Map;
      expect(first['snapshot'], isA<String>());
      final path = s.db.select('PRAGMA database_list').first['file'] as String;
      final writer = external ? Store.open(path, device: 'B') : s;
      try {
        final id = external ? first['rows'][0]['id'] as String : older;
        writer.save('quotation', {
          ...writer.get('quotation', id)!.data,
          'notes': external ? 'external change' : 'move to first page',
        }, id: id);
      } finally {
        if (external) writer.close();
      }
      if (!external) {
        // Without a token, moving the unseen row to the front repeats the
        // already-seen row and silently omits the edited one.
        expect(
          s.queryRecords('quotation', offset: 1, limit: 1).rows.single['id'],
          first['rows'][0]['id'],
        );
      }
      for (final tool in ['query', 'related']) {
        final args = tool == 'query'
            ? {'type': 'quotation'}
            : {'link': 'quotation.supplier_id', 'id': sup};
        expect(
          run(tool, {...args, 'offset': 1, 'snapshot': first['snapshot']}),
          containsPair('error', contains('snapshot')),
        );
        expect(
          run(tool, {...args, 'offset': 1}),
          containsPair('error', contains('snapshot')),
        );
      }
    }
  });

  test('a snapshot cannot be reused on another connection', () {
    final first = s.queryRecords('quotation');
    final path = s.db.select('PRAGMA database_list').first['file'] as String;
    final other = Store.open(path, device: 'B');
    try {
      expect(
        () => other.queryRecords('quotation', expectedSnapshot: first.snapshot),
        throwsFormatException,
      );
    } finally {
      other.close();
    }
  });

  test('business limit reduces budget details while keeping full totals', () {
    for (var i = 0; i < 50; i++) {
      s.save(
        'project_item',
        item(
          pro,
          'material',
          productId: prod,
          name: List.filled(150, '长').join(),
          cost: '2',
        ),
      );
    }
    final result =
        run('project_budget', {'project_id': pro, 'limit': 1}) as Map;
    expect(result['total'], 50);
    expect(result['returned'], 1);
    expect(result['truncated'], true);
    expect(result['cost'], '100');
    expect(result['lines'], hasLength(1));
    expect(jsonEncode(result).length, lessThan(2000));
  });

  test('bounded business outputs disclose totals and truncation', () {
    final lines = <String>[];
    for (var i = 0; i < 51; i++) {
      lines.add(s.save('project_item', item(pro, 'material', productId: prod)));
      s.save('quotation', quotation(sup, prod, pro, '1'));
    }
    final inquiry = s.createInquiry(
      pro,
      '询价',
      itemIds: lines,
      supplierIds: [sup],
    );
    final outputs = [
      run('project_budget', {'project_id': pro, 'limit': 50}) as Map,
      run('inquiry_matrix', {'inquiry_id': inquiry, 'limit': 50}) as Map,
      (run('compare_quotes', {'product_id': prod, 'limit': 50}) as List).single
          as Map,
      (run('quote_options', {
                    'project_id': pro,
                    'product_id': prod,
                    'limit': 50,
                  })
                  as List)
              .first
          as Map,
    ];
    for (final result in outputs) {
      expect(result['total'], 51);
      expect(result['returned'], 50);
      expect(result['truncated'], true);
    }
  });
}
