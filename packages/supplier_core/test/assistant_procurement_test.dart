import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

AssistantWebSnapshot page({
  String host = 'seller-a.example',
  String seller = 'Seller A',
  String model = 'A100',
  String price = '100',
  Map<String, String?> fields = const {},
}) {
  final facts = <String, String?>{
    'unit': '件',
    'currency': 'CNY',
    'tax_mode': 'included',
    'tax_rate': '13',
    'min_qty': '1',
    'quoted_on': '2026-08-31',
    'valid_until': '2026-12-31',
    'shipping': 'included',
    'configuration': '8 cores',
    'manufacture_country': '中国',
    'brand_origin': '中国',
    'cpu.cores': '8核',
    ...fields,
  };
  return AssistantWebSnapshot.capture(
    url: 'https://$host/product',
    title: 'Product',
    fetchedAt: '2026-09-01T00:00:00Z',
    text: 'Captured original product page',
    truncated: false,
    jsonLd: [
      jsonEncode({
        '@type': 'Product',
        'name': 'Server',
        'brand': 'Brand',
        'model': model,
        'additionalProperty': [
          for (final entry in facts.entries)
            if (entry.value != null)
              {
                '@type': 'PropertyValue',
                'name': entry.key,
                'value': entry.value,
              },
        ],
        'offers': {
          '@type': 'Offer',
          'price': price,
          'priceCurrency': facts['currency'],
          'seller': {'name': seller},
          'validFrom': facts['quoted_on'],
          'priceValidUntil': facts['valid_until'],
        },
      }),
    ],
  );
}

void main() {
  late Store store;
  late AiCancellation cancellation;
  var calls = 0;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('procurement');
    store = device('P');
    cancellation = AiCancellation();
    calls = 0;
  });
  tearDown(() {
    store.close();
    tmp.deleteSync(recursive: true);
  });
  AssistantProcurementTools tools(
    List<AssistantWebSnapshot> pages, {
    Future<bool> Function(AssistantActionPreview)? approve,
    AssistantPermission permission = AssistantPermission.confirmWrites,
    String? Function()? domesticCriterion,
    void Function()? validateSession,
  }) => AssistantProcurementTools(
    store,
    web: AssistantWebTools(restoredSnapshots: pages),
    sessionId: 'job',
    permission: permission,
    approve: approve ?? (_) async => true,
    domesticCriterion: domesticCriterion,
    validateSession: validateSession,
  );
  Future<Map<String, dynamic>> run(
    AssistantProcurementTools t,
    String name,
    Map<String, Object?> args, {
    String? callId,
  }) async =>
      jsonDecode(
            await t.execute(
              name,
              args,
              callId: callId ?? 'call-${calls++}',
              cancellation: cancellation,
            ),
          )
          as Map<String, dynamic>;
  Future<String> stage(
    AssistantProcurementTools t,
    AssistantWebSnapshot source, {
    String? itemId,
  }) async =>
      (await run(t, 'procurement_stage', {
            'source_id': source.id,
            'row_id': source.products.single.id,
            if (itemId != null) 'item_id': itemId,
          }))['candidate_id']
          as String;
  String budget({String requirement = '物理核数>=8核；中国制造', String model = 'A100'}) {
    final projectId = store.save('project', project('P'));
    final productId = store.save('product', {
      ...product('Original'),
      'brand': 'Brand',
      'model': model,
    });
    final supplierId = store.save('supplier', supplier('Original supplier'));
    final quoteId = store.save(
      'quotation',
      quotation(supplierId, productId, projectId, '250'),
    );
    return store.save('project_item', {
      ...item(
        projectId,
        'material',
        productId: productId,
        quotationId: quoteId,
        cost: '250',
      ),
      'requirement': requirement,
    });
  }

  test(
    'fully explicit formal project unit price is compared with the reference interval',
    () async {
      final itemId = budget();
      final line = store.get('project_item', itemId)!;
      final material = store.get('product', line.data['product_id'] as String)!;
      store.save('product', {
        ...material.data,
        'attributes': {'configuration': '8 cores'},
      }, id: material.id);
      final quote = store.get(
        'quotation',
        line.data['quotation_id'] as String,
      )!;
      store.save('quotation', {
        ...quote.data,
        'includes': ['freight'],
        'quoted_on': '2026-08-31',
        'valid_until': '2026-12-31',
      }, id: quote.id);
      final a = page(),
          b = page(host: 'second.test', seller: 'B', price: '120.50');
      final t = tools([a, b]);
      final ids = [
        await stage(t, a, itemId: itemId),
        await stage(t, b, itemId: itemId),
      ];
      final result = await run(t, 'procurement_compare', {
        'candidate_ids': ids,
        'item_id': itemId,
      });
      final diff = result['project_difference'] as Map;
      expect(diff['status'], 'comparable_unit_price');
      expect(diff['position'], 'above_reference_range');
      expect(diff['difference_from_min'], '150');
      expect(diff['difference_from_max'], '129.5');
      expect(diff['scope'], contains('单价'));
    },
  );
  test(
    'incomplete project context reports specific missing conditions',
    () async {
      final itemId = budget(),
          a = page(),
          b = page(host: 'second.test', seller: 'B', price: '120');
      final t = tools([a, b]);
      final ids = [
        await stage(t, a, itemId: itemId),
        await stage(t, b, itemId: itemId),
      ];
      final result = await run(t, 'procurement_compare', {
        'candidate_ids': ids,
        'item_id': itemId,
      });
      final diff = result['project_difference'] as Map;
      expect(diff['status'], 'not_comparable');
      expect((diff['reasons'] as List).join(' '), contains('配置'));
      expect((diff['reasons'] as List).join(' '), contains('运费'));
      expect(diff.containsKey('difference_from_min'), isFalse);
    },
  );
  test(
    'local midnight uses the same expiry date as formal budget quotes',
    () async {
      final localNow = DateTime(2026, 10, 2, 0, 30);
      store = Store(store.db, device: 'P', clock: () => localNow);
      final itemId = budget();
      final line = store.get('project_item', itemId)!;
      final quote = store.get(
        'quotation',
        line.data['quotation_id'] as String,
      )!;
      store.save('quotation', {
        ...quote.data,
        'valid_until': '2026-10-01',
      }, id: quote.id);
      expect(
        store
            .quoteOptions(
              line.data['project_id'] as String,
              line.data['product_id'] as String,
            )
            .single
            .valid,
        isFalse,
      );
      final a = page(fields: {'valid_until': '2026-10-01'});
      final b = page(
        host: 'midnight.test',
        seller: 'Midnight seller',
        price: '120',
        fields: {'valid_until': '2026-10-01'},
      );
      final t = tools([a, b]);
      final ids = [
        await stage(t, a, itemId: itemId),
        await stage(t, b, itemId: itemId),
      ];
      final report = await run(t, 'procurement_compare', {
        'candidate_ids': ids,
        'item_id': itemId,
      });
      expect(report['as_of'], '2026-10-02');
      expect(report['status'], 'insufficient_evidence');
      expect(report['excluded'], hasLength(2));
      expect(jsonEncode(report['excluded']), contains('报价过期'));
      expect(report.containsKey('min'), isFalse);
      expect(a.fetchedAt, '2026-09-01T00:00:00Z');
    },
  );
  test(
    'display refreshes expired comparisons and does not show old ranges',
    () async {
      var today = DateTime.utc(2026, 9, 1);
      store = Store(store.db, device: 'P', clock: () => today);
      final a = page(),
          b = page(host: 'second.test', seller: 'B', price: '120');
      final t = tools([a, b]);
      final ids = [await stage(t, a), await stage(t, b)];
      await run(t, 'procurement_compare', {'candidate_ids': ids});
      today = DateTime.utc(2027, 1, 1);
      final report = t.renderReport(
        AssistantAnswer.fromRun('', [], modelCalls: 1, elapsed: Duration.zero),
      );
      expect(report, isNot(contains('"status":"reference_range"')));
      expect(report, contains('insufficient_evidence'));
      expect(report, contains('2027-01-01'));
      expect(report, isNot(contains('"min":"100"')));
    },
  );
  test(
    'display rejects comparison after unbound target budget changes',
    () async {
      final itemId = budget(),
          a = page(),
          b = page(host: 'second.test', seller: 'B', price: '120');
      final t = tools([a, b]);
      final ids = [await stage(t, a), await stage(t, b)];
      await run(t, 'procurement_compare', {
        'candidate_ids': ids,
        'item_id': itemId,
      });
      final line = store.get('project_item', itemId)!;
      store.save('project_item', {...line.data, 'qty': '2'}, id: itemId);
      final report = t.renderReport(
        AssistantAnswer.fromRun('', [], modelCalls: 1, elapsed: Duration.zero),
      );
      expect(report, contains('stale_comparison'));
      expect(report, isNot(contains('"status":"reference_range"')));
      expect(report, isNot(contains('"min":"100"')));
    },
  );
  test(
    'research supports explicit requirements; reviewed import persists reference evidence and preserves budget',
    () async {
      final source = page(model: 'B100'), itemId = budget();
      final before = store.get('project_item', itemId)!;
      final t = tools(
        [source],
        approve: (p) async {
          expect(p.after['source'], isA<Map>());
          expect(p.after['requirement'], before.data['requirement']);
          return true;
        },
      );
      final id = await stage(t, source, itemId: itemId);
      final check = await run(t, 'procurement_check', {'candidate_id': id});
      expect(check['status'], 'source_supported');
      await expectLater(
        run(t, 'procurement_import', {
          'candidate_id': id,
          'operation': 'replace',
        }),
        throwsFormatException,
      );
      final result = await run(t, 'procurement_import', {
        'candidate_id': id,
        'operation': 'catalog',
      }, callId: 'import');
      expect(result['status'], 'applied');
      expect(
        store
            .get('quotation', result['quotation_id'] as String)!
            .data['price_basis'],
        'reference',
      );
      expect(store.get('project_item', itemId)!.data, before.data);
      expect(store.get('project_item', itemId)!.version, before.version);
      final attachment = store.attachment(result['attachment_id'] as String)!;
      expect(
        store
            .get('product', result['product_id'] as String)!
            .data['source_attachment_ids'],
        [attachment.id],
      );
      expect(
        store
            .paramsOf(result['product_id'] as String)
            .values
            .single
            .data['source'],
        'import',
      );
      expect(utf8.decode(attachment.bytes!), contains(source.digest));
      expect(utf8.decode(attachment.bytes!), contains('selected_row_id'));
      expect(
        store
            .paramsOf(result['product_id'] as String)
            .values
            .single
            .data['confirmed'],
        isFalse,
      );
      final replay = await run(tools([]), 'procurement_import', {
        'candidate_id': id,
        'operation': 'catalog',
      }, callId: 'import');
      expect(jsonEncode(replay), jsonEncode(result));
      expect(t.appliedActions, hasLength(1));
    },
  );
  test(
    'same-basis independent sellers yield exact reference interval',
    () async {
      final a = page(),
          b = page(host: 'seller-b.test', seller: 'Seller B', price: '120.50');
      final itemId = budget();
      final t = tools([a, b]);
      final ids = [
        await stage(t, a, itemId: itemId),
        await stage(t, b, itemId: itemId),
      ];
      final result = await run(t, 'procurement_compare', {
        'candidate_ids': ids,
        'item_id': itemId,
      });
      expect(result['status'], 'reference_range');
      expect(result['min'], '100');
      expect(result['max'], '120.5');
    },
  );
  test(
    'model prefix, units, MOQ, date and duplicate sellers are excluded',
    () async {
      final itemId = budget();
      for (final bad in [
        page(host: 'bad.test', seller: 'B', model: 'A100-Pro'),
        page(host: 'bad.test', seller: 'B', fields: {'unit': '箱'}),
        page(host: 'bad.test', seller: 'B', fields: {'min_qty': '100'}),
        page(host: 'bad.test', seller: 'B', fields: {'quoted_on': null}),
        page(
          host: 'bad.test',
          seller: 'B',
          fields: {'valid_until': '2026-08-01'},
        ),
        page(host: 'bad.test', seller: 'Seller A'),
      ]) {
        final a = page(), t = tools([page(), bad]);
        // A fresh task ID keeps this test within the per-task candidate cap.
        store.db.execute(
          "DELETE FROM meta WHERE key LIKE 'assistant_procurement:%'",
        );
        final ids = [
          await stage(t, a, itemId: itemId),
          await stage(t, bad, itemId: itemId),
        ];
        final result = await run(t, 'procurement_compare', {
          'candidate_ids': ids,
          'item_id': itemId,
        });
        expect(result['status'], 'insufficient_evidence');
        expect(result['excluded'], isNotEmpty);
      }
    },
  );
  test(
    'unparsed clauses and country ambiguity never become supported',
    () async {
      final source = page(
        fields: {'manufacture_country': 'DE', 'brand_origin': '中国'},
      );
      for (final requirement in ['国产', '中国制造', '物理核数>=8核且满足全部国家规范', '符合国家标准']) {
        final itemId = budget(requirement: requirement);
        final t = tools([source]);
        final id = await stage(t, source, itemId: itemId);
        final report = await run(t, 'procurement_check', {'candidate_id': id});
        expect(report['status'], isNot('source_supported'));
      }
      final itemId = budget(requirement: '国产');
      final t = tools([source], domesticCriterion: () => 'brand');
      final id = await stage(t, source, itemId: itemId);
      expect(
        (await run(t, 'procurement_check', {'candidate_id': id}))['status'],
        'source_supported',
      );
    },
  );
  test(
    'missing core quote fields imports material only and never substitutes fetch date',
    () async {
      final source = page(fields: {'quoted_on': null, 'min_qty': null}),
          itemId = budget();
      final t = tools([source]);
      final id = await stage(t, source, itemId: itemId);
      final result = await run(t, 'procurement_import', {
        'candidate_id': id,
        'operation': 'catalog',
      });
      expect(result['quotation_id'], isNull);
      expect(result['product_id'], isNotNull);
      final noUnit = page(fields: {'unit': null});
      final t2 = tools([noUnit]);
      final id2 = await stage(t2, noUnit, itemId: itemId);
      await expectLater(
        run(t2, 'procurement_import', {
          'candidate_id': id2,
          'operation': 'catalog',
        }),
        throwsFormatException,
      );
    },
  );
  test('forged IDs and model fact overrides are rejected', () async {
    final source = page(), t = tools([page()]);
    await expectLater(
      run(t, 'procurement_stage', {
        'source_id': 'fake',
        'row_id': source.products.single.id,
      }),
      throwsFormatException,
    );
    await expectLater(
      run(t, 'procurement_stage', {'source_id': source.id, 'row_id': 'fake'}),
      throwsFormatException,
    );
    await expectLater(
      run(t, 'procurement_stage', {
        'source_id': source.id,
        'row_id': source.products.single.id,
        'values': {'price': '1'},
      }),
      throwsFormatException,
    );
    await expectLater(
      run(t, 'procurement_import', {
        'candidate_id': 'fake',
        'operation': 'catalog',
      }),
      throwsFormatException,
    );
    for (final type in ['product', 'quotation'])
      expect(
        () => guardAssistantProcurementWrite('create_record', type, {
          'name': 'Fake',
        }),
        throwsFormatException,
      );
    for (final field in [
      'product_id',
      'quotation_id',
      'unit_cost',
      'unit_price',
      'requirement',
    ])
      expect(
        () => guardAssistantProcurementWrite('update_record', 'project_item', {
          field: null,
        }),
        throwsFormatException,
      );
  });
  test(
    'approval denial, cancellation, readonly and stale versions write no imports',
    () async {
      final source = page(), itemId = budget();
      final setup = tools([source]);
      final id = await stage(setup, source, itemId: itemId);
      final args = {'candidate_id': id, 'operation': 'catalog'};
      expect(
        (await run(
          tools([], approve: (_) async => false),
          'procurement_import',
          args,
        ))['status'],
        'denied',
      );
      await expectLater(
        run(
          tools([], permission: AssistantPermission.readOnly),
          'procurement_import',
          args,
        ),
        throwsFormatException,
      );
      await expectLater(
        run(
          tools(
            [],
            approve: (_) async {
              cancellation.cancel();
              return true;
            },
          ),
          'procurement_import',
          args,
        ),
        throwsA(isA<LlmException>()),
      );
      cancellation = AiCancellation();
      await expectLater(
        run(
          tools(
            [],
            approve: (_) async {
              final r = store.get('project_item', itemId)!;
              store.save('project_item', {
                ...r.data,
                'requirement': 'Changed',
              }, id: itemId);
              return true;
            },
          ),
          'procurement_import',
          args,
        ),
        throwsFormatException,
      );
      expect(store.db.select('SELECT * FROM attachment'), isEmpty);
      expect(store.db.select('SELECT * FROM product'), hasLength(1));
    },
  );
  test(
    'database reopen and cache cleanup preserve authoritative import receipt',
    () async {
      final source = page(), itemId = budget();
      final t = tools([source]);
      final id = await stage(t, source, itemId: itemId);
      final args = {'candidate_id': id, 'operation': 'catalog'};
      final first = await t.execute(
        'procurement_import',
        args,
        callId: 'durable',
        cancellation: cancellation,
      );
      final path =
          store.db.select('PRAGMA database_list').first['file'] as String;
      store.close();
      store = Store.open(path, device: 'P');
      final restored = tools(
        [],
        approve: (_) async {
          fail('Replay must not ask approval');
        },
      );
      restored.clearTransient();
      final replay = await restored.execute(
        'procurement_import',
        args,
        callId: 'durable',
        cancellation: cancellation,
      );
      expect(replay, first);
      expect(restored.appliedActions, hasLength(1));
      expect(
        store.attachment((jsonDecode(first) as Map)['attachment_id'] as String),
        isNotNull,
      );
      await expectLater(
        restored.execute(
          'procurement_import',
          {'candidate_id': 'other', 'operation': 'catalog'},
          callId: 'durable',
          cancellation: cancellation,
        ),
        throwsFormatException,
      );
      await expectLater(
        run(
          tools(
            [],
            validateSession: () => throw StateError('restored database'),
          ),
          'procurement_import',
          args,
          callId: 'durable',
        ),
        throwsStateError,
      );
    },
  );
  test(
    'receipt failure rolls back supplier material parameters quote and attachment',
    () async {
      final source = page(), itemId = budget();
      final t = tools([source]);
      final id = await stage(t, source, itemId: itemId);
      final before = content(store);
      store.db.execute(
        "CREATE TRIGGER fail_procurement BEFORE INSERT ON meta WHEN NEW.key LIKE 'assistant_procurement_receipt:%' BEGIN SELECT RAISE(ABORT,'receipt failed'); END",
      );
      await expectLater(
        run(t, 'procurement_import', {
          'candidate_id': id,
          'operation': 'catalog',
        }),
        throwsA(isA<Exception>()),
      );
      expect(content(store), before);
      expect(store.db.select('SELECT * FROM attachment'), isEmpty);
    },
  );
  test(
    'host report ignores malicious model text and reloads original candidate evidence',
    () async {
      final source = page(), itemId = budget();
      final t = tools([source]);
      await stage(t, source, itemId: itemId);
      final answer = AssistantAnswer.fromRun(
        'FAKE VERIFIED MODEL PRICE 0',
        [],
        modelCalls: 1,
        elapsed: Duration.zero,
      );
      final report = tools([]).renderReport(answer);
      expect(report, isNot(contains('FAKE VERIFIED')));
      expect(report, contains(source.url));
      expect(report, contains('source_supported'));
    },
  );
}
