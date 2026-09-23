import 'dart:io';
import 'package:test/test.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_core/src/query/candidates.dart';
import 'package:supplier_core/src/query/search_keys.dart';
import 'support/test_rig.dart';
import 'domain_test.dart' show quote;

void main() {
  late Directory directory;
  late StorageTestRig rig;
  late QueryRepository query;
  var event = 0;
  String id(int n) =>
      '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
  RevisionEnvelope env(
    String type,
    int n,
    Map<String, Object?> payload, {
    List<String> parents = const [],
    String kind = 'put',
  }) => RevisionEnvelope.create(
    entityType: type,
    entityId: id(n),
    parents: parents,
    kind: kind,
    payload: payload,
    authoredAt: '2026-09-17T00:00:00.000Z',
    originDeviceId: id(999999),
  );
  RevisionEnvelope supplier(int n) => env('supplier', n, {
    'name': 'Supplier $n',
    'aliases': ['Alias $n'],
    'address': null,
    'categories': <String>[],
    'notes': null,
  });
  RevisionEnvelope product(int n) => env('product', n, {
    'name': 'ＢＯＬＴ $n',
    'brand': 'Straße',
    'model': 'AB-01/%',
    'unit': '件',
    'specification': null,
    'category': null,
    'notes': null,
  });
  RevisionEnvelope contact(int n, {int supplierId = 1}) => env('contact', n, {
    'supplier_id': id(supplierId),
    'name': 'Buyer $n',
    'phone': '10086',
    'wechat': null,
    'email': null,
    'notes': null,
  });
  RevisionEnvelope quotation(
    int n, {
    int supplierId = 1,
    int productId = 10,
    Map<String, Object?> changes = const {},
    List<String> parents = const [],
  }) => env('quotation', n, {
    ...quote(),
    'supplier_id': id(supplierId),
    'product_id': id(productId),
    'valid_until': '2026-09-30',
    if (changes['contact_id'] != null)
      'contact_snapshot': {
        'name': 'Buyer 30',
        'phone': '10086',
        'wechat': null,
        'email': null,
      },
    ...changes,
  }, parents: parents);
  Future<void> batch(List<RevisionEnvelope> records) async {
    final job = 'query-${event++}';
    await rig.database.createJob(job);
    await rig.database.transaction(() async {
      for (final row in records) {
        await rig.database.appendStaging(job, row);
      }
    });
    final token = await rig.database.sealJob(job, 'query-decisions');
    await rig.database.registerConfirmation(job, token);
    await rig.coordinator().commitStaged(
      jobId: job,
      expectedPreviewToken: token,
      confirmationEventId: job,
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('query-test-');
    rig = StorageTestRig(File('${directory.path}/business.sqlite'));
    query = QueryRepository(
      rig.database,
      calendarClock: () => DateTime(2026, 9, 17),
    );
    await batch([
      supplier(1),
      supplier(2),
      supplier(3),
      product(10),
      product(11),
    ]);
  });
  tearDown(() async {
    await rig.database.close();
    await directory.delete(recursive: true);
  });

  test(
    'latest supplier comparison and name filters retain ties and cursor fencing',
    () async {
      await batch([
        contact(30),
        quotation(
          20,
          changes: {
            'contact_id': id(30),
            'quoted_on': '2026-09-15',
            'tax_mode': 'excluded',
          },
        ),
        quotation(
          21,
          changes: {
            'contact_id': id(30),
            'quoted_on': '2026-09-16',
            'price': '12.000001',
            'tax_mode': 'excluded',
          },
        ),
        quotation(
          22,
          changes: {
            'contact_id': id(30),
            'quoted_on': '2026-09-16',
            'price': '12.000002',
            'tax_mode': 'excluded',
          },
        ),
      ]);
      final filters = <String, Object?>{
        'view': 'latest',
        'supplier_name': 'Supplier 1',
        'contact_name': 'Buyer 30',
        'sort': 'price_asc',
      };
      final first = await query.quotations(filters, limit: 1);
      expect(first.items.single.id, id(21));
      final next = await query.quotations(
        filters,
        limit: 1,
        cursor: first.nextCursor,
      );
      expect(next.items.single.id, id(22));
      await batch([supplier(4)]);
      await expectLater(
        query.quotations(filters, cursor: first.nextCursor),
        throwsA(isA<DomainFailure>()),
      );
      expect(
        (await query.quotations({...filters, 'contact_name': 'missing'})).items,
        isEmpty,
      );
    },
  );

  test(
    'latest keeps uncertain validity and tax visible without claiming minimum',
    () async {
      await batch([
        quotation(
          20,
          changes: {
            'valid_until': null,
            'tax_mode': 'unknown',
            'quoted_on': '2026-09-16',
          },
        ),
      ]);
      final latest = await query.quotations({'view': 'latest'});
      expect(latest.items.single.id, id(20));
      expect(latest.items.single.comparisonExclusions, isNotEmpty);
      expect(
        (await query.quotations({'view': 'confirmed_lowest'})).items,
        isEmpty,
      );
    },
  );

  test(
    'workspace entity lists use version-bound keyset pages and detail',
    () async {
      await batch([contact(30), contact(31, supplierId: 2), quotation(20)]);
      final first = await query.entities('supplier', limit: 1);
      expect(first.items, hasLength(1));
      expect(first.items.single.type, 'supplier');
      expect(first.items.single.name, 'Supplier 1');
      expect(first.nextCursor, isNotNull);
      final second = await query.entities(
        'supplier',
        cursor: first.nextCursor,
        limit: 1,
      );
      expect(second.items.single.id, isNot(first.items.single.id));
      final detail = await query.entity('supplier', first.items.single.id);
      expect(detail?.payload?['aliases'], ['Alias 1']);
      expect(await query.referenceImpact('supplier', id(1)), greaterThan(0));
      expect(
        (await query.entities('supplier', search: 'PPLIER 2')).items.single.id,
        id(2),
      );
      expect(
        (await query.entities('contact', supplierId: id(1))).items.single.id,
        id(30),
      );

      await batch([supplier(99)]);
      await expectLater(
        query.entities('supplier', cursor: first.nextCursor, limit: 1),
        throwsA(
          isA<DomainFailure>().having(
            (error) => error.code,
            'code',
            'stale_cursor',
          ),
        ),
      );
    },
  );
  test('history materializes page keys before display joins', () async {
    await batch([quotation(100), quotation(101)]);
    final plan = await query.explain({
      'product_name': 'bolt',
      'text_mode': 'prefix',
    });
    expect(plan.join(' '), contains('MATERIALIZE page'));
    final first = await query.quotations({
      'product_name': 'bolt',
      'text_mode': 'prefix',
    }, limit: 1);
    final second = await query.quotations(
      {'product_name': 'bolt', 'text_mode': 'prefix'},
      limit: 1,
      cursor: first.nextCursor,
    );
    expect({first.items.single.id, second.items.single.id}, {id(100), id(101)});
    expect(first.items.single.values['product_name'], 'ＢＯＬＴ 10');
  });
  test('NFKC full casefold whitespace and model punctuation search only', () {
    expect(searchKey('  ＳＴＲＡＳＳＥ\u00a0 Straße\tΣςσ  '), 'strasse strasse σσσ');
    expect(searchKey('ＡＢ-０１/%'), 'ab-01/%');
    expect(searchKey('İ'), 'i\u0307');
    expect(searchKey('ﬃ'), 'ffi');
  });
  test(
    'stable paged ordering equals independent date/price oracle for limits1/50/200',
    () async {
      final records = [
        for (var i = 0; i < 211; i++)
          quotation(
            1000 + i,
            changes: {
              'price': '${i % 13}.${(i % 5).toString().padLeft(6, '0')}',
              'capture_mode': 'historical',
              'inquiry_precision': i % 11 == 0 ? 'unknown' : 'date',
              'inquiry_date': i % 11 == 0
                  ? null
                  : '2026-09-${(1 + i % 16).toString().padLeft(2, '0')}',
            },
          ),
      ];
      await batch(records);
      for (final sort in ['inquiry_date_desc', 'quoted_on_desc', 'price_asc']) {
        final expected = [...records]
          ..sort((a, b) {
            final result = sort == 'price_asc'
                ? Quotation.fromJson(
                    a.payload,
                  ).priceKey.compareTo(Quotation.fromJson(b.payload).priceKey)
                : ((b.payload[sort == 'quoted_on_desc'
                                  ? 'quoted_on'
                                  : 'inquiry_date']
                              as String?) ??
                          '')
                      .compareTo(
                        (a.payload[sort == 'quoted_on_desc'
                                    ? 'quoted_on'
                                    : 'inquiry_date']
                                as String?) ??
                            '',
                      );
            return result != 0 ? result : a.entityId.compareTo(b.entityId);
          });
        for (final limit in [1, 50, 200]) {
          String? cursor;
          final actual = <String>[];
          do {
            final page = await query.quotations(
              {'sort': sort},
              cursor: cursor,
              limit: limit,
            );
            actual.addAll(page.items.map((r) => r.id));
            cursor = page.nextCursor;
          } while (cursor != null);
          expect(actual, expected.map((r) => r.entityId).toList());
        }
      }
    },
  );
  test('cursor binds filters and all database version dimensions', () async {
    await batch([quotation(1000), quotation(1001)]);
    final first = await query.quotations({}, limit: 1);
    expect(first.nextCursor, isNotNull);
    await expectLater(
      query.quotations({'currency': 'USD'}, cursor: first.nextCursor),
      throwsA(
        isA<DomainFailure>().having((e) => e.code, 'code', 'invalid_cursor'),
      ),
    );
    await batch([quotation(1002)]);
    await expectLater(
      query.quotations({}, cursor: first.nextCursor),
      throwsA(
        isA<DomainFailure>().having((e) => e.code, 'code', 'stale_cursor'),
      ),
    );
    for (final limit in [0, 201]) {
      await expectLater(
        query.quotations({}, limit: limit),
        throwsArgumentError,
      );
    }
    await expectLater(
      query.quotations({'arbitrary_sql': 'DROP TABLE revision'}),
      throwsA(isA<DomainFailure>()),
    );
  });
  test(
    'full price groups latest supplier date ties and all minimum ties',
    () async {
      await batch([
        quotation(1000, changes: {'price': '1', 'quoted_on': '2026-09-14'}),
        quotation(1001, changes: {'price': '10', 'tax_mode': 'excluded'}),
        quotation(1002, changes: {'price': '10', 'tax_mode': 'excluded'}),
        quotation(
          1003,
          supplierId: 2,
          changes: {'price': '10', 'tax_mode': 'excluded'},
        ),
        quotation(
          1004,
          supplierId: 3,
          changes: {'price': '0', 'valid_until': null, 'tax_mode': 'excluded'},
        ),
        quotation(
          1005,
          supplierId: 3,
          changes: {
            'price': '0',
            'quoted_on': '2026-09-14',
            'valid_until': '2026-09-15',
            'tax_mode': 'excluded',
          },
        ),
        quotation(
          1006,
          supplierId: 3,
          changes: {
            'price': '0',
            'quoted_on': '2026-09-18',
            'tax_mode': 'excluded',
          },
        ),
        quotation(
          1007,
          supplierId: 3,
          changes: {'price': '0', 'tax_mode': 'unknown'},
        ),
        quotation(
          1008,
          changes: {'price': '2', 'currency': 'USD', 'tax_mode': 'excluded'},
        ),
        quotation(
          1009,
          changes: {'price': '3', 'min_qty': '2', 'tax_mode': 'excluded'},
        ),
        quotation(
          1010,
          changes: {'price': '4', 'tax_mode': 'included', 'tax_rate': null},
        ),
        quotation(
          1011,
          changes: {'price': '5', 'tax_mode': 'included', 'tax_rate': '13'},
        ),
        quotation(
          1012,
          changes: {'price': '0', 'unit_snapshot': '箱', 'tax_mode': 'excluded'},
        ),
        quotation(
          1013,
          changes: {
            'price': '8',
            'unit_snapshot': 'historical',
            'tax_mode': 'excluded',
            'capture_mode': 'historical',
            'inquirer_name': null,
          },
        ),
        quotation(
          1014,
          changes: {
            'price': '1',
            'quoted_on': '2026-09-14',
            'tax_mode': 'excluded',
          },
        ),
      ]);
      final result = await query.quotations({
        'view': 'confirmed_lowest',
        'as_of': '2026-09-17',
      });
      expect(result.items.map((r) => r.id).toSet(), {
        for (final n in [1001, 1002, 1003, 1008, 1009, 1010, 1011, 1012, 1013])
          id(n),
      });
      expect(result.items.every((r) => r.comparisonExclusions.isEmpty), isTrue);
      expect((await query.quotations({})).items, hasLength(15));
    },
  );
  test(
    'history retains deleted/conflicted reference rows and snapshots',
    () async {
      await batch([
        quotation(1000, changes: {'tax_mode': 'excluded'}),
      ]);
      await batch([
        env(
          'supplier',
          1,
          {},
          parents: [supplier(1).revisionId],
          kind: 'delete',
        ),
      ]);
      final history = await query.quotations({'supplier_id': id(1)});
      expect(history.items, hasLength(1));
      expect(
        history.items.single.comparisonExclusions,
        contains('supplier_not_active'),
      );
      expect(
        (await query.quotations({'view': 'confirmed_lowest'})).items,
        isEmpty,
      );
      final root = product(10);
      await batch([
        env(
          'product',
          10,
          {...root.payload, 'name': 'Conflicted A'},
          parents: [root.revisionId],
        ),
        env(
          'product',
          10,
          {...root.payload, 'name': 'Conflicted B'},
          parents: [root.revisionId],
        ),
      ]);
      expect(
        (await query.quotations({'product_name': 'conflicted b'})).items,
        hasLength(1),
      );
    },
  );
  test(
    'conflicting quotations filter through any head without choosing a winner',
    () async {
      final root = quotation(1000);
      await batch([root]);
      await batch([
        quotation(1000, changes: {'price': '1'}, parents: [root.revisionId]),
        quotation(
          1000,
          productId: 11,
          changes: {'price': '2'},
          parents: [root.revisionId],
        ),
      ]);
      final page = await query.quotations({
        'product_id': id(11),
        'price_min': '2',
        'price_max': '2',
      });
      expect(page.items.single.conflicted, isTrue);
      expect(page.items.single.payload, isNull);
      final first = await query.quotationHeads(id(1000), limit: 1);
      final second = await query.quotationHeads(
        id(1000),
        cursor: first.nextCursor,
        limit: 1,
      );
      expect({
        first.items.single.values['revision_id'],
        second.items.single.values['revision_id'],
      }, hasLength(2));
    },
  );
  test(
    'exact prefix contains candidates return stable reasons without wildcard interpretation',
    () async {
      final exact = await query.candidates('product', {'brand': 'STRASSE'});
      expect(exact, hasLength(2));
      expect(exact.first.reasons, ['brand:exact']);
      expect(
        (await query.candidates('product', {'model': 'AB-01/%'})).length,
        2,
      );
      expect(await query.candidates('product', {'model': 'AB-01/_'}), isEmpty);
      expect(
        (await query.candidates('supplier', {
          'aliases': 'Alias',
        }, mode: SearchMode.prefix)).length,
        3,
      );
      expect(
        (await query.candidates('product', {
          'model': '01/',
        }, mode: SearchMode.contains)).length,
        2,
      );
      final plans = await CandidateRepository(
        rig.database,
      ).explain('product', 'model', 'ab-', mode: SearchMode.prefix);
      expect(plans.join('\n'), contains('search_key>? AND search_key<?'));
      expect(
        (await rig.database.findRevision(
          product(10).revisionId,
        ))!.payload['model'],
        'AB-01/%',
      );
    },
  );
  test(
    'normalized project/person and date/price/missing filters compose',
    () async {
      await batch([
        quotation(
          1000,
          changes: {
            'project_number': '０００Ａ',
            'inquirer_name': '  Straße ',
            'price': '12.000001',
          },
        ),
        quotation(
          1001,
          changes: {
            'capture_mode': 'historical',
            'inquiry_precision': 'unknown',
            'inquiry_date': null,
            'quoted_on': null,
            'valid_until': null,
            'project_name': null,
            'project_number': null,
            'inquirer_name': null,
          },
        ),
      ]);
      expect(
        (await query.quotations({
          'project_number': '000a',
          'inquirer_name': 'STRASSE',
          'inquiry_from': '2026-09-16',
          'inquiry_to': '2026-09-16',
          'price_min': '12.000001',
          'price_max': '12.000001',
        })).items.single.id,
        id(1000),
      );
      expect(
        (await query.quotations({
          'inquiry_missing': true,
          'missing_context': true,
        })).items.single.id,
        id(1001),
      );
      expect(
        (await query.quotations({'project_number': "' OR 1=1 --"})).items,
        isEmpty,
      );
    },
  );
  for (final field in ['instance', 'epoch']) {
    test(
      'cursor rejects changed $field with same business generation',
      () async {
        await batch([quotation(1000), quotation(1001)]);
        final first = await query.quotations({}, limit: 1);
        await rig.database.customStatement(
          field == 'instance'
              ? "UPDATE database_meta SET instance_id='replacement'"
              : 'UPDATE database_meta SET active_epoch=active_epoch+1',
        );
        await expectLater(
          query.quotations({}, cursor: first.nextCursor),
          throwsA(
            isA<DomainFailure>().having((e) => e.code, 'code', 'stale_cursor'),
          ),
        );
      },
    );
  }
  test(
    'unknown quote dates and validity stay visible pending confirmation',
    () async {
      await batch([
        quotation(
          1000,
          changes: {
            'capture_mode': 'historical',
            'quoted_on': null,
            'valid_until': null,
            'tax_mode': 'included',
            'tax_rate': null,
          },
        ),
      ]);
      final history = await query.quotations({});
      expect(
        history.items.single.comparisonExclusions,
        containsAll(['quoted_on_unknown', 'validity_pending']),
      );
      expect(
        (await query.quotations({'view': 'confirmed_lowest'})).items,
        isEmpty,
      );
    },
  );
  test(
    'conflict summary nulls are not misreported as unknown inquiry date',
    () async {
      final root = quotation(1000);
      await batch([root]);
      await batch([
        quotation(1000, changes: {'price': '1'}, parents: [root.revisionId]),
        quotation(1000, changes: {'price': '2'}, parents: [root.revisionId]),
      ]);
      expect(
        (await query.quotations({'inquiry_missing': true})).items,
        isEmpty,
      );
      expect(
        (await query.quotations({
          'inquiry_missing': false,
        })).items.single.conflicted,
        isTrue,
      );
    },
  );
  test(
    'quote detail preserves snapshot when canonical contact changes',
    () async {
      final first = env('contact', 20, {
        'supplier_id': id(1),
        'name': 'Alice',
        'phone': '111',
        'wechat': null,
        'email': null,
        'notes': null,
      });
      final target = env('contact', 21, {
        'supplier_id': id(1),
        'name': 'Bob',
        'phone': '222',
        'wechat': null,
        'email': null,
        'notes': null,
      });
      final quoted = quotation(
        1000,
        changes: {
          'contact_id': id(20),
          'contact_snapshot': {
            'name': 'Alice',
            'phone': '111',
            'wechat': null,
            'email': null,
          },
        },
      );
      await batch([first, target, quoted]);
      await batch([
        env(
          'contact',
          20,
          {'target_id': id(21)},
          parents: [first.revisionId],
          kind: 'redirect',
        ),
      ]);
      final result = await query.quotations({'contact_id': id(21)});
      expect(result.items.single.values['contact_name'], 'Bob');
      expect(
        (result.items.single.payload!['contact_snapshot'] as Map)['name'],
        'Alice',
      );
    },
  );
  test('conflict head canonical refs refresh after target redirects', () async {
    await batch([product(12)]);
    final root = quotation(1000);
    await batch([root]);
    await batch([
      quotation(1000, changes: {'price': '1'}, parents: [root.revisionId]),
      quotation(
        1000,
        productId: 11,
        changes: {'price': '2'},
        parents: [root.revisionId],
      ),
    ]);
    await batch([
      env(
        'product',
        11,
        {'target_id': id(12)},
        parents: [product(11).revisionId],
        kind: 'redirect',
      ),
    ]);
    final matches = await query.quotations({'product_id': id(12)});
    expect(matches.items.single.id, id(1000));
    expect(matches.items.single.conflicted, isTrue);
    final heads = await query.quotationHeads(id(1000));
    expect(
      heads.items.any((r) => r.values['canonical_product_id'] == id(12)),
      isTrue,
    );
  });
  test(
    'deleted product remains discoverable by historical name brand and model',
    () async {
      await batch([quotation(1000)]);
      await batch([
        env(
          'product',
          10,
          {},
          parents: [product(10).revisionId],
          kind: 'delete',
        ),
      ]);
      expect(
        (await query.quotations({
          'product_name': 'bolt 10',
          'brand': 'strasse',
          'model': 'ab-01/%',
        })).items.single.id,
        id(1000),
      );
      final candidates = await query.candidates('product', {'name': 'bolt 10'});
      expect(candidates.single.id, id(10));
      expect(candidates.single.state, 'deleted');
      expect(candidates.single.displayName, isNull);
    },
  );
  test(
    'prefix successor skips surrogates without admitting unrelated private-use keys',
    () async {
      expect(prefixEnd('\ud7ff'), '\ue000');
      final raw = product(12);
      await batch([
        env('product', 12, {...raw.payload, 'model': '\ud7ff-target'}),
        env('product', 13, {...raw.payload, 'model': '\ue000-unrelated'}),
      ]);
      final candidates = await query.candidates('product', {
        'model': '\ud7ff',
      }, mode: SearchMode.prefix);
      expect(candidates.map((c) => c.id), [id(12)]);
    },
  );
  test(
    'merged product history remains searchable by original and canonical names',
    () async {
      await batch([quotation(1000)]);
      await batch([
        env(
          'product',
          10,
          {'target_id': id(11)},
          parents: [product(10).revisionId],
          kind: 'redirect',
        ),
      ]);
      expect(
        (await query.quotations({'product_name': 'bolt 10'})).items.single.id,
        id(1000),
      );
      expect(
        (await query.quotations({'product_name': 'bolt 11'})).items.single.id,
        id(1000),
      );
    },
  );
  test(
    'parallel deletion heads preserve historical product discovery without winner',
    () async {
      await batch([quotation(1000)]);
      final root = product(10);
      final deleted = env(
        'product',
        10,
        {},
        parents: [root.revisionId],
        kind: 'delete',
      );
      final second = RevisionEnvelope.create(
        entityType: 'product',
        entityId: id(10),
        parents: [root.revisionId],
        kind: 'delete',
        payload: {},
        authoredAt: '2026-09-18T00:00:00.000Z',
        originDeviceId: id(999999),
      );
      await batch([deleted, second]);
      final result = await query.quotations({'product_name': 'bolt 10'});
      expect(result.items.single.id, id(1000));
      expect(result.items.single.values['product_status'], 'conflicted');
      expect(
        (await query.candidates('product', {'model': 'ab-01/%'})).any(
          (c) =>
              c.id == id(10) &&
              c.state == 'conflicted' &&
              c.displayName == null,
        ),
        isTrue,
      );
    },
  );
  test(
    'explicit null included tax rate selects its own comparison group',
    () async {
      await batch([
        quotation(
          1000,
          changes: {'tax_mode': 'included', 'tax_rate': null, 'price': '3'},
        ),
        quotation(
          1001,
          changes: {'tax_mode': 'included', 'tax_rate': '13', 'price': '2'},
        ),
      ]);
      final results = await query.quotations({
        'view': 'confirmed_lowest',
        'tax_mode': 'included',
        'tax_rate': null,
      });
      expect(results.items.single.id, id(1000));
    },
  );
  test(
    'money range distinguishes maximum values one millionth apart',
    () async {
      await batch([
        quotation(1000, changes: {'price': '999999999999.999999'}),
        quotation(1001, changes: {'price': '999999999999.999998'}),
      ]);
      final result = await query.quotations({
        'price_min': '999999999999.999999',
        'price_max': '999999999999.999999',
      });
      expect(result.items.single.id, id(1000));
    },
  );
}
