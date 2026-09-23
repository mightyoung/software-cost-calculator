import 'dart:math';

import 'package:supplier_core/src/contracts.dart';
import 'package:supplier_core/src/domain/revision.dart';
import 'package:supplier_core/src/domain/revision_graph.dart';
import 'package:test/test.dart';

import 'support/graph_memory_workspace.dart';

String entityId(int n) =>
    '00000000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';
String revisionId(int n) => n.toRadixString(16).padLeft(64, '0');

/// Synthetic indexed IDs deliberately isolate graph rules from SHA preimage
/// construction (including corrupted cyclic graph fixtures). T2 tests own hash
/// validation; production input adapters MUST enforce actual envelope hashes.
GraphRevision node(
  int id, {
  int entity = 1,
  List<int> parents = const [],
  String kind = 'put',
  String type = 'supplier',
  int? target,
  Map<String, Object?>? payload,
}) => GraphRevision(
  revisionId(id),
  RevisionEnvelope.create(
    entityType: type,
    entityId: entityId(entity),
    parents: parents.map(revisionId).toList(),
    kind: kind,
    payload:
        payload ??
        (kind == 'delete'
            ? {}
            : kind == 'redirect'
            ? {'target_id': entityId(target!)}
            : {
                'name': 'supplier-$id',
                'aliases': <String>[],
                'address': null,
                'categories': <String>[],
                'notes': null,
              }),
    authoredAt: '2026-09-17T00:00:00.000Z',
    originDeviceId: entityId(999),
  ),
);

Matcher failure(String code) =>
    throwsA(isA<DomainFailure>().having((error) => error.code, 'code', code));
void expectDiscarded(MemoryGraphWorkspace work) {
  expect(work.discarded, 1);
  expect(work.bound, isNull);
  expect(work.anomalyQueue, isEmpty);
  expect(work.anomalyMarks, isEmpty);
  expect(work.remaining, isEmpty);
  expect(work.ready, isEmpty);
  expect(work.roots, isEmpty);
  expect(work.heads, isEmpty);
  expect(work.visits, isEmpty);
  expect(work.walks, isEmpty);
  expect(work.relations, isEmpty);
}

Map<String, Object?> contactPayload(int supplier) => {
  'supplier_id': entityId(supplier),
  'name': 'current contact',
  'phone': '00123',
  'wechat': null,
  'email': null,
  'notes': null,
};
Map<String, Object?> productPayload() => {
  'name': 'product',
  'unit': '件',
  'brand': null,
  'model': null,
  'specification': null,
  'category': null,
  'notes': null,
};
Map<String, Object?> quotationPayload() => {
  'supplier_id': entityId(1),
  'product_id': entityId(2),
  'contact_id': entityId(3),
  'contact_snapshot': {
    'name': 'historical contact',
    'phone': '00123',
    'wechat': null,
    'email': null,
  },
  'price': '0',
  'currency': 'CNY',
  'tax_mode': 'unknown',
  'unit_snapshot': '件',
  'min_qty': '1',
  'quoted_on': null,
  'tax_rate': null,
  'lead_time_days': null,
  'valid_until': null,
  'notes': null,
  'project_name': null,
  'project_number': null,
  'inquiry_location': null,
  'inquirer_name': null,
  'inquiry_precision': 'unknown',
  'inquiry_date': null,
  'inquired_at': null,
  'inquiry_utc_offset_minutes': null,
  'capture_mode': 'historical',
};

void main() {
  test('empty union is valid and version is bound before all reads', () async {
    final work = MemoryGraphWorkspace([]);
    final report = await RevisionGraphValidator(pageSize: 2).validate(work);
    expect(report.revisions, 0);
    expect(report.entities, 0);
    expect(report.heads, 0);
    expect(work.bindingReads, 2);
    expect(report.binding, same(work.bound));
  });
  test(
    '100 fixed-seed DAGs match independent set-difference heads oracle',
    () async {
      for (var seed = 0; seed < 100; seed++) {
        final random = Random(seed);
        final rows = [node(0)];
        for (var i = 1; i < 50; i++) {
          final parents = {
            random.nextInt(i),
            if (random.nextBool()) random.nextInt(i),
          }.toList();
          rows.add(node(i, parents: parents));
        }
        final expected = rows.map((row) => row.id).toSet();
        for (final row in rows) {
          expected.removeAll(row.envelope.parents);
        }
        rows.shuffle(random);
        final work = MemoryGraphWorkspace(rows);
        final report = await RevisionGraphValidator(pageSize: 7).validate(work);
        expect(work.heads, expected, reason: 'seed $seed');
        expect(report.revisions, 50);
        expect(report.heads, expected.length);
        expect(work.maxReturnedPage, lessThanOrEqualTo(7));
      }
    },
  );
  test('single entity deep history remains paged and iterative', () async {
    final work = MemoryGraphWorkspace(
      List.generate(12000, (i) => node(i, parents: i == 0 ? [] : [i - 1])),
    );
    final report = await RevisionGraphValidator(pageSize: 31).validate(work);
    expect(report.revisions, 12000);
    expect(report.entities, 1);
    expect(work.heads, {revisionId(11999)});
    expect(work.maxReturnedPage, 31);
  });
  test(
    'wide fan-out children and heads are not collected by validator',
    () async {
      final work = MemoryGraphWorkspace([
        node(0),
        for (var i = 1; i <= 100; i++) node(i, parents: [0]),
      ]);
      final report = await RevisionGraphValidator(pageSize: 4).validate(work);
      expect(report.heads, 100);
      expect(work.maxReturnedPage, 4);
      expect(
        (await work.relation(GraphEntity('supplier', entityId(1))))!.status,
        GraphRelationStatus.conflicted,
      );
    },
  );
  final invalid = <String, List<GraphRevision>>{
    'graph_missing_parent': [
      node(1, parents: [0]),
    ],
    'graph_multiple_roots': [node(0), node(1)],
    'graph_parent_entity': [
      node(0),
      node(1, entity: 2, parents: [0]),
    ],
    'graph_root_kind': [node(0, kind: 'delete')],
    'graph_cycle': [
      node(0),
      node(1, parents: [0, 2]),
      node(2, parents: [1]),
    ],
    'graph_missing_reference': [
      node(0),
      node(1, parents: [0], kind: 'redirect', target: 2),
    ],
  };
  for (final entry in invalid.entries) {
    test('${entry.key} rejects graph and discards all work', () async {
      final work = MemoryGraphWorkspace(entry.value);
      await expectLater(
        RevisionGraphValidator(pageSize: 1).validate(work),
        failure(entry.key),
      );
      expectDiscarded(work);
    });
  }
  for (final field in ['instance', 'epoch', 'generation', 'job', 'sealed']) {
    test('$field change during scan invalidates entire run', () async {
      final work = MemoryGraphWorkspace([
        node(0),
        node(1, parents: [0]),
      ]);
      work.onRead = (work) {
        if (work.sourceReads != 2) return;
        work.binding = GraphBinding(
          database: DatabaseVersion(
            instanceId: field == 'instance' ? 'restored' : 'database',
            activeEpoch: field == 'epoch' ? 2 : 1,
            generation: field == 'generation' ? 4 : 3,
          ),
          jobId: field == 'job' ? 'other' : 'job',
          sealedDigest: field == 'sealed' ? 'mutated' : 'sealed',
        );
      };
      await expectLater(
        RevisionGraphValidator(pageSize: 1).validate(work),
        failure('graph_stale_binding'),
      );
      expectDiscarded(work);
    });
  }
  test(
    'source exception discards partially built topology and permits fresh retry',
    () async {
      final work = MemoryGraphWorkspace([
        node(0),
        node(1, parents: [0]),
      ]);
      work.onRead = (work) {
        if (work.sourceReads == 2) throw StateError('read I/O');
      };
      await expectLater(
        RevisionGraphValidator(pageSize: 1).validate(work),
        throwsStateError,
      );
      expectDiscarded(work);
      work.onRead = null;
      expect((await RevisionGraphValidator().validate(work)).heads, 1);
    },
  );
  test(
    'redirect cycle and feeder are relation anomalies, preserving valid history',
    () async {
      final work = MemoryGraphWorkspace([
        node(0),
        node(1, entity: 2),
        node(2, entity: 3),
        node(3, parents: [0], kind: 'redirect', target: 2),
        node(4, entity: 2, parents: [1], kind: 'redirect', target: 1),
        node(5, entity: 3, parents: [2], kind: 'redirect', target: 1),
      ]);
      final report = await RevisionGraphValidator(pageSize: 2).validate(work);
      expect(report.revisions, 6);
      expect(report.anomalousEntities, 3);
      for (var i = 1; i <= 3; i++) {
        expect(
          (await work.relation(GraphEntity('supplier', entityId(i))))!.status,
          GraphRelationStatus.redirectCycle,
        );
      }
    },
  );
  test(
    'parallel redirect heads propagate anomaly without choosing a winner',
    () async {
      final work = MemoryGraphWorkspace([
        node(0),
        node(1, entity: 2),
        node(2, entity: 3),
        node(3, parents: [0], kind: 'redirect', target: 2),
        node(4, parents: [0], kind: 'redirect', target: 3),
        node(5, entity: 4),
        node(6, entity: 4, parents: [5], kind: 'redirect', target: 1),
      ]);
      final report = await RevisionGraphValidator().validate(work);
      expect(report.anomalousEntities, 4);
      expect(
        (await work.relation(GraphEntity('supplier', entityId(1))))!.canonical,
        isNull,
      );
      expect(work.heads, containsAll([revisionId(3), revisionId(4)]));
    },
  );
  test(
    'deep redirects use persistent visits and memoized terminal results',
    () async {
      const length = 2000;
      final work = MemoryGraphWorkspace([
        for (var i = 1; i <= length; i++) node(i, entity: i),
        for (var i = 1; i < length; i++)
          node(
            length + i,
            entity: i,
            parents: [i],
            kind: 'redirect',
            target: i + 1,
          ),
      ]);
      final report = await RevisionGraphValidator(pageSize: 29).validate(work);
      expect(report.anomalousEntities, 0);
      expect(
        (await work.relation(GraphEntity('supplier', entityId(1))))!.canonical,
        GraphEntity('supplier', entityId(length)),
      );
      expect(work.walks, isEmpty);
      expect(work.visits, isEmpty);
    },
  );
  test(
    'delete is retained and redirect resolves to tombstone without resurrection',
    () async {
      final work = MemoryGraphWorkspace([
        node(0),
        node(1, parents: [0], kind: 'delete'),
        node(2, entity: 2),
        node(3, entity: 2, parents: [2], kind: 'redirect', target: 1),
      ]);
      await RevisionGraphValidator().validate(work);
      expect(
        (await work.relation(GraphEntity('supplier', entityId(2))))!.status,
        GraphRelationStatus.deleted,
      );
    },
  );
  test(
    'all put payload references exist; tombstones and old snapshots remain valid history',
    () async {
      final work = MemoryGraphWorkspace([
        node(0),
        node(1, entity: 2, type: 'product', payload: productPayload()),
        node(2, entity: 3, type: 'contact', payload: contactPayload(1)),
        node(3, entity: 4, type: 'quotation', payload: quotationPayload()),
        node(4, parents: [0], kind: 'delete'),
      ]);
      expect(
        (await RevisionGraphValidator(pageSize: 1).validate(work)).revisions,
        5,
      );
    },
  );
  for (final missing in [0, 1, 2]) {
    test(
      'missing referenced ${['supplier', 'product', 'contact'][missing]} rejects union',
      () async {
        final rows = [
          node(0),
          node(1, entity: 2, type: 'product', payload: productPayload()),
          node(2, entity: 3, type: 'contact', payload: contactPayload(1)),
          node(3, entity: 4, type: 'quotation', payload: quotationPayload()),
        ]..removeAt(missing);
        final work = MemoryGraphWorkspace(rows);
        await expectLater(
          RevisionGraphValidator().validate(work),
          failure('graph_missing_reference'),
        );
        expectDiscarded(work);
      },
    );
  }
  test(
    'superseded put payload still requires historical reference closure',
    () async {
      final work = MemoryGraphWorkspace([
        node(0),
        node(1, entity: 3, type: 'contact', payload: contactPayload(99)),
        node(
          2,
          entity: 3,
          type: 'contact',
          parents: [1],
          payload: contactPayload(1),
        ),
      ]);
      await expectLater(
        RevisionGraphValidator().validate(work),
        failure('graph_missing_reference'),
      );
    },
  );
  test(
    'reference of wrong entity type is not accepted by matching UUID alone',
    () async {
      final work = MemoryGraphWorkspace([
        node(0),
        node(1, entity: 2, type: 'product', payload: productPayload()),
        node(2, parents: [0], kind: 'redirect', target: 2),
      ]);
      await expectLater(
        RevisionGraphValidator().validate(work),
        failure('graph_missing_reference'),
      );
    },
  );
  test(
    'explicit descendant repairs old redirect cycle without erasing history',
    () async {
      final work = MemoryGraphWorkspace([
        node(0),
        node(1, entity: 2),
        node(2, parents: [0], kind: 'redirect', target: 2),
        node(3, entity: 2, parents: [1], kind: 'redirect', target: 1),
        node(4, parents: [2]),
      ]);
      final result = await RevisionGraphValidator(pageSize: 1).validate(work);
      expect(result.revisions, 5);
      expect(result.anomalousEntities, 0);
      expect(
        (await work.relation(GraphEntity('supplier', entityId(2))))!.canonical,
        GraphEntity('supplier', entityId(1)),
      );
    },
  );
  test(
    'merge of all parallel heads repairs component without using old edges',
    () async {
      final work = MemoryGraphWorkspace([
        node(0),
        node(1, entity: 2),
        node(2, entity: 3),
        node(3, parents: [0], kind: 'redirect', target: 2),
        node(4, parents: [0], kind: 'redirect', target: 3),
        node(5, parents: [3, 4]),
      ]);
      final result = await RevisionGraphValidator(pageSize: 1).validate(work);
      expect(result.revisions, 6);
      expect(result.anomalousEntities, 0);
      expect(work.heads, {revisionId(1), revisionId(2), revisionId(5)});
    },
  );
  test(
    'redirect into conflicted target stays conflicted, with no canonical winner',
    () async {
      final work = MemoryGraphWorkspace([
        node(0),
        node(1, parents: [0]),
        node(2, parents: [0]),
        node(3, entity: 2),
        node(4, entity: 2, parents: [3], kind: 'redirect', target: 1),
      ]);
      await RevisionGraphValidator().validate(work);
      final relation = await work.relation(
        GraphEntity('supplier', entityId(2)),
      );
      expect(relation!.status, GraphRelationStatus.conflicted);
      expect(relation.canonical, isNull);
    },
  );
  test('binding read failure clears prior successful run', () async {
    final work = MemoryGraphWorkspace([node(0)]);
    final validator = RevisionGraphValidator();
    await validator.validate(work);
    work.onBinding = (_) => throw StateError('metadata unavailable');
    await expectLater(validator.validate(work), throwsStateError);
    expectDiscarded(work);
  });
  test(
    'cycle through parallel heads keeps entire component anomalous',
    () async {
      final work = MemoryGraphWorkspace([
        node(0),
        node(1, entity: 2),
        node(2, entity: 3),
        node(3, parents: [0], kind: 'redirect', target: 2),
        node(4, parents: [0], kind: 'redirect', target: 3),
        node(5, entity: 2, parents: [1], kind: 'redirect', target: 1),
      ]);
      final report = await RevisionGraphValidator(pageSize: 1).validate(work);
      expect(report.anomalousEntities, 3);
      for (var i = 1; i <= 3; i++) {
        final result = await work.relation(
          GraphEntity('supplier', entityId(i)),
        );
        expect(result!.status, GraphRelationStatus.parallelRedirect);
        expect(result.canonical, isNull);
      }
    },
  );
  test(
    'missing parent plus cleanup failure preserves both failures and stacks',
    () async {
      final work = MemoryGraphWorkspace([
        node(0),
        node(2, parents: [1]),
      ]);
      final cleanup = StateError('work table I/O failure');
      final cleanupStack = StackTrace.fromString('cleanup injection stack');
      work.onRead = (work) {
        work.discardError = cleanup;
        work.discardStack = cleanupStack;
      };
      DomainFailure? caught;
      try {
        await RevisionGraphValidator(pageSize: 1).validate(work);
        fail('Cleanup failure must not return a validation report');
      } on DomainFailure catch (error) {
        caught = error;
      }
      expect(caught.code, 'graph_cleanup_failed');
      final cause =
          caught.cause!
              as ({
                Object primary,
                StackTrace primaryStack,
                Object cleanup,
                StackTrace cleanupStack,
              });
      expect(
        cause.primary,
        isA<DomainFailure>().having(
          (error) => error.code,
          'code',
          'graph_missing_parent',
        ),
      );
      // Compiler-generated JS names differ from VM symbols. Exact preservation
      // is separately asserted with an injected stack in the metadata case.
      expect(cause.primaryStack.toString().trim(), isNotEmpty);
      expect(cause.cleanup, same(cleanup));
      expect(cause.cleanupStack.toString(), cleanupStack.toString());
      expect(work.quarantined, isTrue);
      final reads = work.sourceReads;
      work.discardError = null;
      await expectLater(
        RevisionGraphValidator().validate(work),
        throwsStateError,
      );
      expect(work.sourceReads, reads);
      await expectLater(work.resetWork(work.binding), throwsStateError);
    },
  );
  test(
    'metadata plus cleanup failure preserves original identity and exact stack',
    () async {
      final work = MemoryGraphWorkspace([node(0)]);
      final primary = StateError('metadata inaccessible');
      final primaryStack = StackTrace.fromString('metadata injection stack');
      final cleanup = StateError('cleanup inaccessible');
      final cleanupStack = StackTrace.fromString('cleanup injection stack');
      work.onBinding = (_) => Error.throwWithStackTrace(primary, primaryStack);
      work.discardError = cleanup;
      work.discardStack = cleanupStack;
      try {
        await RevisionGraphValidator().validate(work);
        fail('Metadata failure must not return a validation report');
      } on DomainFailure catch (error) {
        expect(error.code, 'graph_cleanup_failed');
        final cause =
            error.cause!
                as ({
                  Object primary,
                  StackTrace primaryStack,
                  Object cleanup,
                  StackTrace cleanupStack,
                });
        expect(cause.primary, same(primary));
        expect(cause.primaryStack.toString(), primaryStack.toString());
        expect(cause.cleanup, same(cleanup));
        expect(cause.cleanupStack.toString(), cleanupStack.toString());
      }
      expect(work.sourceReads, 0);
      expect(work.quarantined, isTrue);
    },
  );
  test(
    'successful cleanup rethrows original metadata failure with original stack',
    () async {
      final work = MemoryGraphWorkspace([node(0)]);
      final primary = StateError('metadata inaccessible');
      final primaryStack = StackTrace.fromString('original metadata stack');
      work.onBinding = (_) => Error.throwWithStackTrace(primary, primaryStack);
      try {
        await RevisionGraphValidator().validate(work);
        fail('Metadata failure must not return a validation report');
      } catch (error, stack) {
        expect(error, same(primary));
        expect(stack.toString(), primaryStack.toString());
      }
      expectDiscarded(work);
      expect(work.quarantined, isFalse);
    },
  );
}
