import 'dart:convert';
import 'dart:io';

import 'package:cryptography/dart.dart';
import 'package:supplier_core/src/ai_runtime.dart';
import 'package:supplier_core/src/assistant_web_catalog.dart';
import 'package:supplier_core/src/assistant_web_tools.dart';
import 'package:test/test.dart';

AssistantWebSnapshot capture(
  String text, {
  List<String> jsonLd = const [],
  bool truncated = false,
}) => AssistantWebSnapshot.capture(
  url: 'https://example.com/product',
  title: 'Catalog',
  fetchedAt: '2026-10-01T00:00:00.000Z',
  text: text,
  truncated: truncated,
  jsonLd: jsonLd,
);
Map<String, Object?> product({
  Object? offers,
  String name = 'Pump',
  String model = 'P100',
}) => {
  '@type': 'Product',
  'name': name,
  'model': model,
  'brand': {
    '@type': 'Brand',
    'name': 'Pump Co',
    'address': {'addressCountry': 'DE'},
  },
  'offers':
      offers ??
      {
        '@type': 'Offer',
        'price': '125.50',
        'priceCurrency': 'CNY',
        'seller': {'name': 'Supplier'},
        'priceValidUntil': '2026-12-31',
      },
};
Future<Map<String, dynamic>> run(
  AssistantWebTools tools,
  String name,
  Map<String, Object?> args,
) async =>
    jsonDecode(
          await tools.execute(
            name,
            args,
            callId: 'catalog-test',
            cancellation: AiCancellation(),
          ),
        )
        as Map<String, dynamic>;

void main() {
  Map<String, Object?> legacyJson(AssistantWebSnapshot snapshot) {
    final json = Map<String, Object?>.from(snapshot.toJson())
      ..remove('json_ld');
    final payload = {
      for (final key in [
        'url',
        'title',
        'fetched_at',
        'text',
        'truncated',
        'products',
      ])
        key: json[key],
    };
    final digest = const DartSha256()
        .hashSync(utf8.encode(jsonEncode(payload)))
        .bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return {...json, 'id': 'web_$digest', 'digest': digest};
  }

  test('marker-free legacy snapshots preserve original identity', () {
    final legacy = legacyJson(capture('名称：Pump\n型号：P100\n价格：100'));
    final restored = AssistantWebSnapshot.fromJson(legacy);
    expect(restored.toJson(), legacy);
    expect(restored.products.single.facts['price'], '100');
  });

  test('ambiguous legacy declaration markers require a fresh capture', () {
    final legacy = legacyJson(
      capture('名称：Pump\n型号：P100\n价格：100\n[Folio JSON-LD declaration]\n{}'),
    );
    expect(() => AssistantWebSnapshot.fromJson(legacy), throwsFormatException);
  });

  test('structured declarations are immutable digest-bound and restorable', () {
    final snapshot = capture(
      'Visible\n[Folio JSON-LD declaration]\ntext',
      jsonLd: [jsonEncode(product())],
    );
    expect(snapshot.products.single.facts['price'], '125.50');
    expect(
      AssistantWebSnapshot.fromJson(snapshot.toJson()).toJson(),
      snapshot.toJson(),
    );
    expect(() => snapshot.jsonLd.clear(), throwsUnsupportedError);
    final changed = {
      ...snapshot.toJson(),
      'json_ld': [jsonEncode(product(name: 'Other'))],
    };
    expect(() => AssistantWebSnapshot.fromJson(changed), throwsFormatException);
    for (final invalid in [
      null,
      'declaration',
      [1],
      List.filled(9, '{}'),
      ['x' * 16001],
    ]) {
      expect(
        () => AssistantWebSnapshot.fromJson({
          ...snapshot.toJson(),
          'json_ld': invalid,
        }),
        throwsFormatException,
      );
    }
  });

  test('visible declaration markers cannot hide price qualifiers', () {
    final snapshot = capture(
      '名称：Pump\n型号：P100\n价格：100\n'
      '[Folio JSON-LD declaration]\n此价格为整批总价，非单价',
    );
    expect(snapshot.products.single.facts, isNot(contains('price')));
    expect(
      AssistantWebSnapshot.fromJson(snapshot.toJson()).products.single.facts,
      isNot(contains('price')),
    );
  });

  test('visible declaration markers cannot manufacture JSON-LD evidence', () {
    final snapshot = capture(
      'Ordinary text\n[Folio JSON-LD declaration]\n${jsonEncode(product())}',
    );
    expect(snapshot.products, isEmpty);
  });

  test(
    'additional property price cannot substitute for an Offer own price',
    () {
      for (final offers in <Object?>[
        [],
        [null],
        {'@type': 'Offer'},
        {'@type': 'Offer', 'price': null},
        {
          '@type': 'Offer',
          'price': {'value': '100'},
        },
        {
          '@type': 'Offer',
          'price': ['100'],
        },
      ]) {
        final data = product()..['offers'] = offers;
        data['additionalProperty'] = [
          {'@type': 'PropertyValue', 'name': 'price', 'value': '100'},
          {'@type': 'PropertyValue', 'name': 'currency', 'value': 'CNY'},
          {'@type': 'PropertyValue', 'name': 'unit', 'value': '台'},
          {'@type': 'PropertyValue', 'name': 'supplier', 'value': 'S'},
        ];
        final row = capture('', jsonLd: [jsonEncode(data)]).products.single;
        expect(row.facts, isNot(contains('price')), reason: jsonEncode(offers));
        expect(row.warnings, isNotEmpty);
      }
    },
  );
  test(
    'unreadable late fields and truncated context cannot preserve a price',
    () {
      final commercial = '名称：Pump\n型号：P100\n币种：CNY\n单位：台\n供应商：S\n价格：100';
      final oversizedField = capture(
        '$commercial\n价格：${'1' * 800}',
      ).products.single;
      expect(oversizedField.facts, isNot(contains('price')));
      expect(oversizedField.warnings, isNotEmpty);
      expect(
        capture('$commercial\n${'x' * 30000}').products.single.facts,
        isNot(contains('price')),
      );
      expect(
        capture(
          '',
          truncated: true,
          jsonLd: [jsonEncode(product())],
        ).products.single.facts,
        isNot(contains('price')),
      );
    },
  );

  test('late JSON-LD commercial property conflicts are not skipped', () {
    final data = product()
      ..['additionalProperty'] = [
        ...List.generate(
          40,
          (i) => {'@type': 'PropertyValue', 'name': '参数$i', 'value': 'v'},
        ),
        {'@type': 'PropertyValue', 'name': 'price', 'value': '999'},
      ];
    final row = capture('', jsonLd: [jsonEncode(data)]).products.single;
    expect(row.facts, isNot(contains('price')));
    expect(row.warnings, isNotEmpty);
  });
  test(
    'late conflicting prices remain visible across the full bounded record',
    () {
      final row = capture(
        '名称：Pump\n型号：P100\n币种：CNY\n单位：台\n供应商：S\n价格：100\n${List.filled(510, '普通说明').join('\n')}\n价格：200',
      ).products.single;
      expect(row.facts, isNot(contains('price')));
      expect(row.warnings, isNotEmpty);
    },
  );

  test(
    'separate context disqualifies totals starting prices and non-unit quotes',
    () {
      for (final qualifier in [
        '此价格为10台总价，非单价',
        '此价格为起价',
        '十台总价',
        '该价格为整套合计金额',
        'starting price',
        'total price for 10 units',
      ]) {
        final row = capture(
          '名称：Pump\n型号：P100\n币种：CNY\n单位：台\n供应商：S\n价格：100\n说明：$qualifier',
        ).products.single;
        expect(row.facts, isNot(contains('price')), reason: qualifier);
        expect(row.warnings, isNotEmpty);
        final jsonRow = capture(
          '',
          jsonLd: [
            jsonEncode(
              product(
                offers: {
                  '@type': 'Offer',
                  'price': '100',
                  'priceCurrency': 'CNY',
                  'seller': {'name': 'S'},
                  'description': qualifier,
                },
              ),
            ),
          ],
        ).products.single;
        expect(jsonRow.facts, isNot(contains('price')), reason: qualifier);
      }
    },
  );

  test('Chinese model alternatives without whitespace cannot bind a quote', () {
    for (final model in [
      'P100或P200',
      'P100或者P200',
      'P100和P200',
      'P100及P200',
      'P100与P200',
      'P100以及P200',
      'P100、P200',
    ]) {
      final row = capture(
        '名称：Pump\n型号：$model\n币种：CNY\n单位：台\n供应商：S\n价格：100',
      ).products.single;
      expect(row.facts, isNot(contains('price')), reason: model);
      expect(
        capture(
          '',
          jsonLd: [jsonEncode(product(model: model))],
        ).products.single.facts,
        isNot(contains('price')),
        reason: model,
      );
    }
  });
  test(
    'explicit single-product labels preserve fields and technical evidence',
    () {
      final snapshot = capture(
        '产品名称：水泵\n型号：P100\n品牌：A\n供应商：S\n价格：125.50\n币种：CNY\n单位：台\n制造国：中国\n功率：2.2 kW\n税率：13%',
      );
      final row = snapshot.products.single;
      expect(row.facts['name'], '水泵');
      expect(row.facts['price'], '125.50');
      expect(row.facts['manufacture_country'], '中国');
      expect(row.parameters, {'功率': '2.2 kW'});
      expect(row.evidence['price'], '价格：125.50');
      expect(row.evidence['parameter:功率'], '功率：2.2 kW');
      expect(row.facts, isNot(contains('brand_origin')));
      expect(() => row.facts['price'] = '1', throwsUnsupportedError);
      expect(() => snapshot.products.clear(), throwsUnsupportedError);
    },
  );

  test(
    'unknown and cost-estimate labels do not become product quote facts',
    () {
      expect(capture('型号：P100\n价格：100').products, isEmpty);
      final row = capture(
        '名称：Pump\n型号：P100\n造价：5000\n预算：1000\n地址：中国\n未知字段：data',
      ).products.single;
      expect(row.facts.keys, unorderedEquals(['name', 'model']));
      expect(row.parameters, isEmpty);
    },
  );

  test(
    'multiple model bindings and conflicting prices cannot yield a price',
    () {
      for (final fields in [
        '型号：P100/P200\n价格：100',
        '型号：P100\n型号：P200\n价格：100',
        '型号：P100\n价格：100\n价格：200',
      ]) {
        final row = capture('名称：Pump\n$fields').products.single;
        expect(row.facts, isNot(contains('price')));
        expect(row.warnings, isNotEmpty);
      }
      expect(
        capture('名称：Pump A\n型号：A\n价格：100\n名称：Pump B\n型号：B\n价格：200').products,
        isEmpty,
      );
    },
  );

  test(
    'ranges starting prices negotiable and malformed values remain missing',
    () {
      for (final price in [
        '100起',
        '100-200',
        '面议',
        'from 100',
        '约100',
        '0',
        '-1',
        '1e9',
        '100 元/台',
      ]) {
        final row = capture('名称：Pump\n型号：P100\n价格：$price').products.single;
        expect(row.facts, isNot(contains('price')), reason: price);
      }
    },
  );

  test(
    'JSON-LD Product Offer is bound and does not infer manufacturing origin',
    () {
      final data = product()
        ..['additionalProperty'] = [
          {'@type': 'PropertyValue', 'name': '功率', 'value': '2.2 kW'},
          {'@type': 'PropertyValue', 'name': '单位', 'value': '台'},
        ];
      final snapshot = capture('Product page', jsonLd: [jsonEncode(data)]);
      final row = snapshot.products.single;
      expect(row.facts['price'], '125.50');
      expect(row.facts['supplier'], 'Supplier');
      expect(row.facts['unit'], '台');
      expect(row.facts, isNot(contains('manufacture_country')));
      expect(row.facts, isNot(contains('brand_origin')));
      expect(row.parameters['功率'], '2.2 kW');
      expect(snapshot.text, 'Product page');
      expect(snapshot.jsonLd.single, contains('"@type":"Product"'));
      expect(row.evidence['price'], contains('Product.offers.price'));
    },
  );

  test('distinct JSON-LD products retain separate model price bindings', () {
    final snapshot = capture(
      '',
      jsonLd: [
        jsonEncode({
          '@graph': [
            product(model: 'A'),
            product(model: 'B', offers: {'@type': 'Offer', 'price': '200'}),
          ],
        }),
      ],
    );
    expect(snapshot.products.map((r) => r.facts['model']), ['A', 'B']);
    expect(snapshot.products.map((r) => r.facts['price']), ['125.50', '200']);
    expect(snapshot.products.map((r) => r.id).toSet().length, 2);
  });

  test('ambiguous JSON-LD offer or mismatched product has no usable price', () {
    for (final offer in [
      {
        '@type': 'AggregateOffer',
        'price': '100',
        'lowPrice': '100',
        'highPrice': '200',
      },
      [
        {'@type': 'Offer', 'price': '100'},
        {'@type': 'Offer', 'price': '200'},
      ],
      {'@type': 'Offer', 'price': '100', 'description': '起价'},
      {
        '@type': 'Offer',
        'price': '100',
        'itemOffered': {'name': 'Pump', 'model': 'OTHER'},
      },
      {
        '@type': 'Offer',
        'price': '100',
        'priceSpecification': {'price': '90'},
      },
    ]) {
      final row = capture(
        '',
        jsonLd: [jsonEncode(product(offers: offer))],
      ).products.single;
      expect(row.facts, isNot(contains('price')));
    }
    final noOffer = product()..remove('offers');
    noOffer['additionalProperty'] = [
      {'@type': 'PropertyValue', 'name': 'price', 'value': '100'},
    ];
    expect(
      capture('', jsonLd: [jsonEncode(noOffer)]).products.single.facts,
      isNot(contains('price')),
    );
  });

  test(
    'duplicate JSON keys deep nesting and oversized declarations are rejected',
    () {
      for (final raw in [
        '{"@type":"Product","name":"Pump","offers":{"@type":"Offer","price":"100","price":"200"}}',
        '${'[' * 40}${jsonEncode(product())}${']' * 40}',
        '${' ' * 16000}${jsonEncode(product())}',
      ]) {
        expect(capture('', jsonLd: [raw]).products, isEmpty);
      }
    },
  );

  test('truncating a numeric field cannot manufacture a different price', () {
    final prefix = '名称：Pump\n型号：P100\n${'x' * 23960}\n价格：';
    final snapshot = capture('$prefix${'1' * 100}');
    expect(snapshot.truncated, true);
    expect(snapshot.products.single.facts, isNot(contains('price')));
  });

  test('restore validates digest facts parameters and strict shape', () {
    final original = capture('名称：Pump\n型号：P100\n价格：100\n功率：2kW');
    expect(
      AssistantWebSnapshot.fromJson(original.toJson()).toJson(),
      original.toJson(),
    );
    for (final field in ['text', 'digest', 'id', 'url']) {
      final json = Map<String, Object?>.from(original.toJson())
        ..[field] = 'tampered';
      expect(() => AssistantWebSnapshot.fromJson(json), throwsFormatException);
    }
    final tampered =
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>;
    tampered['products'][0]['parameters']['功率'] = '200kW';
    expect(
      () => AssistantWebSnapshot.fromJson(tampered),
      throwsFormatException,
    );
    expect(
      () => AssistantWebSnapshot.fromJson({
        ...original.toJson(),
        'approved': true,
      }),
      throwsFormatException,
    );
  });

  test(
    'web fetch captures JSON-LD rows and restores immutable versioned snapshots',
    () async {
      final callbacks = <AssistantWebSnapshot>[];
      var amount = '100';
      final tools = AssistantWebTools(
        onSnapshot: callbacks.add,
        resolver: (_) async => [InternetAddress('8.8.8.8')],
        transport: (uri, addresses, cancellation) async => AssistantWebResponse(
          statusCode: 200,
          contentType: 'text/html',
          body: Stream.value(
            utf8.encode(
              '<h1>Catalog</h1><script type="application/ld+json">${jsonEncode(product(offers: {'@type': 'Offer', 'price': amount}))}</script>',
            ),
          ),
        ),
      );
      final first = await run(tools, 'web_fetch', {
        'url': 'https://example.com/product',
      });
      final id = first['source_id'] as String;
      final rows = await run(tools, 'web_product_rows', {'source_id': id});
      expect((rows['products'] as List).single['facts']['price'], '100');
      amount = '200';
      final second = await run(tools, 'web_fetch', {
        'url': 'https://example.com/product',
      });
      expect(second['source_id'], isNot(id));
      expect(tools.snapshot(id)!.products.single.facts['price'], '100');
      expect(callbacks.length, 2);
      final restored = AssistantWebTools(restoredSnapshots: tools.snapshots);
      expect(await run(restored, 'web_product_rows', {'source_id': id}), rows);
      expect(
        await run(restored, 'web_product_rows', {
          'source_id': id,
          'price': '1',
        }),
        contains('error'),
      );
      expect(
        await run(restored, 'web_product_rows', {'source_id': 'invented'}),
        contains('error'),
      );
      expect(() => tools.snapshots.clear(), throwsUnsupportedError);
    },
  );
}
