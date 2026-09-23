import 'dart:io';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';
import 'support/test_rig.dart';
import 'domain_test.dart' show quote;

void main() {
  late Directory directory;
  late StorageTestRig rig;
  late RecordService service;
  var sequence = 100;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('supplier-record-');
    rig = StorageTestRig(File('${directory.path}/business.sqlite'));
    service = RecordService(
      rig.coordinator(),
      deviceId: '00000000-0000-4000-8000-999999999999',
      clock: () => DateTime.utc(2026, 9, 17),
      newId: () =>
          '00000000-0000-4000-8000-${(sequence++).toString().padLeft(12, '0')}',
    );
  });
  tearDown(() async {
    await rig.database.close();
    await directory.delete(recursive: true);
  });
  Map<String, Object?> supplier([String name = 'Supplier']) => {
    'name': name,
    'aliases': <String>[],
    'address': null,
    'categories': <String>[],
    'notes': null,
  };
  Map<String, Object?> product() => {
    'name': 'Product',
    'unit': '件',
    'brand': 'brand',
    'model': 'model',
    'specification': null,
    'category': null,
    'notes': null,
  };
  Future<Set<String>> heads(String id) async => (await rig.database.rows(
    'SELECT revision_id FROM entity_head WHERE entity_id=?',
    [Variable(id)],
  )).map((r) => r.read<String>('revision_id')).toSet();
  Future<Map<String, Object?>> quotePayload() async {
    final sid = await service.createEntity('supplier', supplier());
    final pid = await service.createEntity('product', product());
    return {...quote(), 'supplier_id': sid, 'product_id': pid};
  }

  test('create correct delete restore and CAS stale protection', () async {
    final id = await service.createEntity('supplier', supplier());
    final original = await heads(id);
    await service.correctEntity(
      'supplier',
      id,
      supplier('changed'),
      expectedHeads: original,
    );
    await expectLater(
      service.correctEntity(
        'supplier',
        id,
        supplier('stale'),
        expectedHeads: original,
      ),
      throwsA(isA<DomainFailure>()),
    );
    await service.deleteEntity('supplier', id, await heads(id));
    expect(
      (await rig.database.findRevision((await heads(id)).single))!.kind,
      'delete',
    );
    await service.restoreEntity(
      'supplier',
      id,
      supplier('restored'),
      await heads(id),
    );
    expect(
      (await rig.database.findRevision(
        (await heads(id)).single,
      ))!.payload['name'],
      'restored',
    );
    expect((await rig.database.currentVersion()).generation, 4);
  });
  test(
    'generic create rejects quotation, dedicated create and copy enforce standard',
    () async {
      final payload = await quotePayload();
      await expectLater(
        service.createEntity('quotation', payload),
        throwsA(isA<DomainFailure>()),
      );
      final id = await service.createQuotation({
        ...payload,
        'capture_mode': 'historical',
      });
      final copied = await service.copyQuotation(id, {
        'inquirer_name': 'Other',
      });
      expect(copied, isNot(id));
      expect(
        (await rig.database.findRevision(
          (await heads(copied)).single,
        ))!.payload['capture_mode'],
        'standard',
      );
      await expectLater(
        service.copyQuotation(id, {'inquirer_name': null}),
        throwsFormatException,
      );
    },
  );
  test(
    'quotation clearing requires explicit acknowledgement and cannot downgrade',
    () async {
      final payload = await quotePayload();
      final id = await service.createQuotation({...payload, 'notes': 'keep'});
      await expectLater(
        service.correctEntity(
          'quotation',
          id,
          payload,
          expectedHeads: await heads(id),
        ),
        throwsFormatException,
      );
      await service.correctEntity(
        'quotation',
        id,
        payload,
        expectedHeads: await heads(id),
        allowExplicitClear: true,
      );
      await expectLater(
        service.correctEntity('quotation', id, {
          ...payload,
          'capture_mode': 'historical',
        }, expectedHeads: await heads(id)),
        throwsFormatException,
      );
    },
  );
  test(
    'contact binding validates supplier and immutable capture snapshot',
    () async {
      final payload = await quotePayload();
      final contactPayload = <String, Object?>{
        'supplier_id': payload['supplier_id'],
        'name': 'Alice',
        'phone': '123',
        'wechat': null,
        'email': null,
        'notes': null,
      };
      final contact = await service.createEntity('contact', contactPayload);
      final snapshot = {
        'name': 'Alice',
        'phone': '123',
        'wechat': null,
        'email': null,
      };
      final id = await service.createQuotation({
        ...payload,
        'contact_id': contact,
        'contact_snapshot': snapshot,
      });
      await expectLater(
        service.createQuotation({
          ...payload,
          'contact_id': contact,
          'contact_snapshot': {...snapshot, 'name': 'Wrong'},
        }),
        throwsFormatException,
      );
      final other = await service.createEntity('supplier', supplier('Other'));
      await expectLater(
        service.createQuotation({
          ...payload,
          'supplier_id': other,
          'contact_id': contact,
          'contact_snapshot': snapshot,
        }),
        throwsFormatException,
      );
      await service.correctEntity('contact', contact, {
        ...contactPayload,
        'phone': '456',
      }, expectedHeads: await heads(contact));
      await service.correctEntity('quotation', id, {
        ...payload,
        'contact_id': contact,
        'contact_snapshot': snapshot,
        'notes': 'snapshot retained',
      }, expectedHeads: await heads(id));
      expect(
        ((await rig.database.findRevision(
              (await heads(id)).single,
            ))!.payload['contact_snapshot']
            as Map)['phone'],
        '123',
      );
    },
  );
  test(
    'notes correction preserves deleted historical association IDs',
    () async {
      final payload = await quotePayload();
      final id = await service.createQuotation(payload);
      final supplierId = payload['supplier_id']! as String;
      await service.deleteEntity(
        'supplier',
        supplierId,
        await heads(supplierId),
      );
      await service.correctEntity('quotation', id, {
        ...payload,
        'notes': 'later note',
      }, expectedHeads: await heads(id));
      final revision = (await rig.database.findRevision(
        (await heads(id)).single,
      ))!;
      expect(revision.payload['supplier_id'], supplierId);
      expect(revision.payload['notes'], 'later note');
    },
  );
  test(
    'notes after supplier merge and contact correction retain original snapshot',
    () async {
      final payload = await quotePayload();
      final source = payload['supplier_id']! as String;
      final contactPayload = <String, Object?>{
        'supplier_id': source,
        'name': 'Alice',
        'phone': '123',
        'wechat': null,
        'email': null,
        'notes': null,
      };
      final contact = await service.createEntity('contact', contactPayload);
      final snapshot = {
        'name': 'Alice',
        'phone': '123',
        'wechat': null,
        'email': null,
      };
      final original = {
        ...payload,
        'contact_id': contact,
        'contact_snapshot': snapshot,
      };
      final id = await service.createQuotation(original);
      final target = await service.createEntity('supplier', supplier('target'));
      await service.mergeEntities(
        'supplier',
        source,
        target,
        supplier('target'),
        {source: await heads(source), target: await heads(target)},
      );
      await service.correctEntity('contact', contact, {
        ...contactPayload,
        'phone': '456',
      }, expectedHeads: await heads(contact));
      await service.correctEntity('quotation', id, {
        ...original,
        'notes': 'later',
      }, expectedHeads: await heads(id));
      final after = (await rig.database.findRevision(
        (await heads(id)).single,
      ))!;
      expect(after.payload['supplier_id'], source);
      expect(after.payload['contact_snapshot'], snapshot);
    },
  );
  test('local cleanup failure surfaces committed receipt context', () async {
    await rig.database.currentVersion();
    await rig.database.customStatement(
      "CREATE TRIGGER block_local_cleanup BEFORE DELETE ON graph_revision BEGIN SELECT RAISE(ABORT,'cleanup'); END",
    );
    try {
      await service.createEntity('supplier', supplier());
      fail('Expected cleanup failure');
    } on DomainFailure catch (error) {
      expect(error.code, 'graph_cleanup_failed');
      final dynamic cause = error.cause;
      expect(cause.committedReceipt, isA<CommitReceipt>());
      expect((await rig.database.currentVersion()).generation, 1);
    }
  });
  test(
    'unaffected projections stay untouched and dependent canonical refs update',
    () async {
      final payload = await quotePayload();
      final id = await service.createQuotation(payload);
      final untouched = await service.createEntity(
        'supplier',
        supplier('unaffected'),
      );
      final target = await service.createEntity(
        'supplier',
        supplier('canonical'),
      );
      final source = payload['supplier_id']! as String;
      await rig.database.customStatement(
        "CREATE TRIGGER protect_untouched BEFORE DELETE ON supplier_projection WHEN OLD.entity_id='$untouched' BEGIN SELECT RAISE(ABORT,'unaffected projection touched'); END",
      );
      await service.mergeEntities(
        'supplier',
        source,
        target,
        supplier('merged'),
        {source: await heads(source), target: await heads(target)},
      );
      final row = (await rig.database.rows(
        'SELECT supplier_id,canonical_supplier_id FROM quotation_projection WHERE entity_id=?',
        [Variable(id)],
      )).single;
      expect(row.read<String>('supplier_id'), source);
      expect(row.read<String>('canonical_supplier_id'), target);
    },
  );
  test(
    'local after-commit response loss recovers same event without duplicate',
    () async {
      final flaky = RecordService(
        rig.coordinator(
          fault: (point) async {
            if (point == 'after_commit') throw StateError('response lost');
          },
        ),
        deviceId: service.deviceId,
      );
      final id = await flaky.createEntity('supplier', supplier());
      expect(await heads(id), hasLength(1));
      expect((await rig.database.currentVersion()).generation, 1);
    },
  );
  test(
    'merge redirects source and repair creates one canonical keeper',
    () async {
      final source = await service.createEntity('supplier', supplier('source'));
      final target = await service.createEntity('supplier', supplier('target'));
      await service.mergeEntities(
        'supplier',
        source,
        target,
        supplier('merged'),
        {source: await heads(source), target: await heads(target)},
      );
      expect(
        (await rig.database.rows(
          'SELECT canonical_id FROM alias_projection WHERE entity_id=?',
          [Variable(source)],
        )).single.read<String>('canonical_id'),
        target,
      );
      await service.repairAliases(
        'supplier',
        {source, target},
        source,
        supplier('keeper'),
        {source: await heads(source), target: await heads(target)},
      );
      expect(
        (await rig.database.rows(
          'SELECT canonical_id FROM alias_projection WHERE entity_id=?',
          [Variable(target)],
        )).single.read<String>('canonical_id'),
        source,
      );
    },
  );
  test(
    'imported historical is allowed but standard ancestry survives deletion',
    () async {
      final payload = await quotePayload();
      final id = await service.createQuotation(payload);
      await service.deleteEntity('quotation', id, await heads(id));
      await expectLater(
        service.restoreEntity('quotation', id, {
          ...payload,
          'capture_mode': 'historical',
        }, await heads(id)),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'standard_downgrade',
          ),
        ),
      );
    },
  );
  test(
    'parallel quote heads retain conflict summary and can resolve all heads',
    () async {
      final payload = await quotePayload();
      final id = await service.createQuotation(payload);
      final initial = (await heads(id)).single;
      await rig.database.createJob('parallel');
      for (final value in ['20', '30']) {
        await rig.database.appendStaging(
          'parallel',
          RevisionEnvelope.create(
            entityType: 'quotation',
            entityId: id,
            parents: [initial],
            kind: 'put',
            payload: {...payload, 'price': value},
            authoredAt: '2026-09-17T00:00:00.000Z',
            originDeviceId: service.deviceId,
          ),
        );
      }
      final token = await rig.database.sealJob('parallel', 'decision');
      await rig.database.registerConfirmation('parallel-event', token);
      await rig.coordinator().commitStaged(
        jobId: 'parallel',
        expectedPreviewToken: token,
        confirmationEventId: 'parallel-event',
      );
      final row = (await rig.database.rows(
        'SELECT * FROM quotation_projection WHERE entity_id=?',
        [Variable(id)],
      )).single;
      expect(row.readNullable<String>('payload'), isNull);
      expect(row.read<String>('relation_status'), 'conflicted');
      await service.resolve('quotation', id, {
        ...payload,
        'price': '25',
      }, await heads(id));
      expect((await heads(id)).length, 1);
    },
  );
}
