import 'dart:io';
import 'package:supplier_core/src/contracts.dart';
import 'package:supplier_core/src/domain/revision.dart';
import 'package:supplier_core/src/data/graph_workspace.dart';
import 'package:supplier_core/src/domain/revision_graph.dart';
import 'package:test/test.dart';
import '../tool/full_chain_scale.dart' show fixture;
import 'support/test_rig.dart';
import 'graph_test.dart'
    show node, contactPayload, productPayload, quotationPayload;

class ScalarWorkspace extends SqlGraphWorkspace {
  ScalarWorkspace(super.database, {required super.jobId, required super.runId});
  @override
  Future<bool> supportsTerminalPages() async => false;
  @override
  Future<void> initializePage(List<GraphRevision> rows) async {
    for (final row in rows) {
      if (row.envelope.parents.isEmpty) {
        if (row.envelope.kind != 'put') {
          throw DomainFailure('graph_root_kind', 'scalar');
        }
        if (!await claimRoot(row.entity, row.id)) {
          throw DomainFailure('graph_multiple_roots', 'scalar');
        }
      }
      for (final id in row.envelope.parents) {
        final parent = await findRevision(id);
        if (parent == null) {
          throw DomainFailure('graph_missing_parent', 'scalar');
        }
        if (parent.entity != row.entity) {
          throw DomainFailure('graph_parent_entity', 'scalar');
        }
      }
      for (final reference in row.references) {
        if (!await hasEntity(reference)) {
          throw DomainFailure('graph_missing_reference', 'scalar');
        }
      }
      await initializeNode(row.id, row.envelope.parents.length);
    }
  }

  @override
  Future<({int processed, int heads})> processReadyBatch(int limit) async {
    final id = await takeReady();
    if (id == null) return (processed: 0, heads: 0);
    String? cursor;
    var children = 0;
    do {
      final page = await readChildren(id, after: cursor, limit: limit);
      for (final child in page.items) {
        await releaseParent(child);
        children++;
      }
      cursor = page.nextCursor;
    } while (cursor != null);
    if (children == 0) await recordHead(id);
    return (processed: 1, heads: children == 0 ? 1 : 0);
  }
}

void main() {
  test(
    'page initialization bounds high fan-in across parent batch boundaries',
    () async {
      final directory = await Directory.systemTemp.createTemp('graph-fan-in-');
      final rig = StorageTestRig(File('${directory.path}/source.sqlite'));
      try {
        await rig.database.createJob('job');
        final root = fixtureRevision(1);
        // Each quoted SHA256 plus separator adds 67 UTF-16 units, except
        // the first separator. Exercise the actual 24,000-unit boundary.
        final parentCount = (24000 - root.canonical.length + 1) ~/ 67;
        final parents = <RevisionEnvelope>[];
        await rig.database.appendStaging('job', root);
        for (var i = 0; i < parentCount; i++) {
          final branch = RevisionEnvelope.create(
            entityType: root.entityType,
            entityId: root.entityId,
            parents: [root.revisionId],
            kind: 'put',
            payload: {
              ...root.payload,
              'notes': '${'备' * 1800}$i',
              'aliases': [for (var j = 0; j < 20; j++) '${'名' * 190}$j'],
              'categories': [for (var j = 0; j < 20; j++) '${'类' * 90}$j'],
            },
            authoredAt: root.authoredAt,
            originDeviceId: root.originDeviceId,
          );
          parents.add(branch);
          await rig.database.appendStaging('job', branch);
        }
        final merge = RevisionEnvelope.create(
          entityType: root.entityType,
          entityId: root.entityId,
          parents: parents.map((p) => p.revisionId).toList(),
          kind: 'put',
          payload: root.payload,
          authoredAt: root.authoredAt,
          originDeviceId: root.originDeviceId,
        );
        expect(parents.first.canonicalBytes.length, greaterThan(20000));
        expect(merge.parents.length, parentCount);
        expect(parentCount, greaterThanOrEqualTo(300));
        expect(
          () => RevisionEnvelope.create(
            entityType: root.entityType,
            entityId: root.entityId,
            parents: [...merge.parents, root.revisionId],
            kind: 'put',
            payload: root.payload,
            authoredAt: root.authoredAt,
            originDeviceId: root.originDeviceId,
          ),
          throwsFormatException,
        );
        await rig.database.appendStaging('job', merge);
        await rig.database.sealJob('job', 'decisions');
        for (final pageSize in [65, 500]) {
          final scalar = await RevisionGraphValidator(pageSize: pageSize)
              .validate(
                ScalarWorkspace(
                  rig.database,
                  jobId: 'job',
                  runId: 'scalar-$pageSize',
                ),
              );
          final batch = await RevisionGraphValidator(pageSize: pageSize)
              .validate(
                SqlGraphWorkspace(
                  rig.database,
                  jobId: 'job',
                  runId: 'batch-$pageSize',
                ),
              );
          expect(batch.revisions, parentCount + 2);
          expect(batch.revisions, scalar.revisions);
          expect(batch.heads, scalar.heads);
          expect(batch.heads, 1);
        }
        final work = SqlGraphWorkspace(
          rig.database,
          jobId: 'job',
          runId: 'bad-parent',
        );
        await work.resetWork(await work.currentBinding());
        final ids = merge.parents;
        // Boundary 64 begins a new fetch; decoding still checks the earlier
        // malformed hash before the later missing parent.
        await rig.database.customStatement(
          'UPDATE graph_revision SET canonical=? WHERE run_id=? AND revision_id=?',
          [root.canonical, 'bad-parent', ids[64]],
        );
        await rig.database.customStatement(
          'DELETE FROM graph_revision WHERE run_id=? AND revision_id=?',
          ['bad-parent', ids[65]],
        );
        await expectLater(
          work.initializePage([GraphRevision(merge.revisionId, merge)]),
          throwsA(
            isA<DomainFailure>().having(
              (e) => e.code,
              'code',
              'revision_hash_mismatch',
            ),
          ),
        );
        await work.discardWork();
      } finally {
        await rig.database.close();
        await directory.delete(recursive: true);
      }
    },
  );
  final root = node(1).envelope;
  RevisionEnvelope changed(
    RevisionEnvelope original, {
    List<String>? parents,
    String? kind,
    Map<String, Object?>? payload,
  }) => RevisionEnvelope.create(
    entityType: original.entityType,
    entityId: original.entityId,
    parents: parents ?? original.parents,
    kind: kind ?? original.kind,
    payload: payload ?? original.payload,
    authoredAt: original.authoredAt,
    originDeviceId: original.originDeviceId,
  );
  final cases = <String, List<RevisionEnvelope>>{
    'root kind': [changed(root, kind: 'delete', payload: {})],
    'multiple roots': [root, node(2).envelope],
    'missing parent': [
      changed(root, parents: ['0' * 64]),
    ],
    'parent entity': [
      root,
      changed(node(2, entity: 2).envelope, parents: [root.revisionId]),
    ],
    'supplier reference': [
      node(3, entity: 3, type: 'contact', payload: contactPayload(1)).envelope,
    ],
    'product reference': [
      root,
      node(
        4,
        entity: 4,
        type: 'quotation',
        payload: {...quotationPayload(), 'contact_id': null},
      ).envelope,
    ],
    'contact reference': [
      root,
      node(2, entity: 2, type: 'product', payload: productPayload()).envelope,
      node(
        4,
        entity: 4,
        type: 'quotation',
        payload: quotationPayload(),
      ).envelope,
    ],
    'redirect reference': [
      root,
      changed(
        root,
        parents: [root.revisionId],
        kind: 'redirect',
        payload: {'target_id': node(2, entity: 2).envelope.entityId},
      ),
    ],
  };
  for (final pageSize in [1, 2, 500]) {
    for (final entry in cases.entries) {
      test('page initialization ${entry.key}, size $pageSize', () async {
        final directory = await Directory.systemTemp.createTemp('graph-init-');
        final rig = StorageTestRig(File('${directory.path}/source.sqlite'));
        try {
          await rig.database.createJob('job');
          for (final row in entry.value) {
            await rig.database.appendStaging('job', row);
          }
          await rig.database.sealJob('job', 'decisions');
          final failures = <String>[];
          for (final work in [
            ScalarWorkspace(rig.database, jobId: 'job', runId: 'scalar'),
            SqlGraphWorkspace(rig.database, jobId: 'job', runId: 'batch'),
          ]) {
            try {
              await RevisionGraphValidator(pageSize: pageSize).validate(work);
              fail('Expected invalid graph');
            } on DomainFailure catch (error) {
              failures.add(error.code);
            }
            final runs = await rig.database.rows(
              "SELECT state FROM graph_run WHERE run_id='${work.runId}'",
            );
            expect(runs.single.read<String>('state'), 'discarded');
            expect(
              await rig.database.rows(
                "SELECT * FROM graph_node WHERE run_id='${work.runId}'",
              ),
              isEmpty,
            );
          }
          expect(failures[1], failures[0]);
        } finally {
          await rig.database.close();
          await directory.delete(recursive: true);
        }
      });
    }
  }
  for (final pageSize in [1, 7, 500]) {
    test('SQL frontier matches scalar with page size $pageSize', () async {
      final directory = await Directory.systemTemp.createTemp('graph-batch-');
      final rig = StorageTestRig(File('${directory.path}/source.sqlite'));
      try {
        await rig.database.createJob('job');
        await rig.database.transaction(() async {
          await for (final revision in fixture(40)) {
            await rig.database.appendStaging('job', revision);
          }
        });
        await rig.database.sealJob('job', 'decisions');
        final validator = RevisionGraphValidator(pageSize: pageSize);
        final scalar = await validator.validate(
          ScalarWorkspace(rig.database, jobId: 'job', runId: 'scalar'),
        );
        final batch = await validator.validate(
          SqlGraphWorkspace(rig.database, jobId: 'job', runId: 'batch'),
        );
        expect(batch.revisions, scalar.revisions);
        expect(batch.heads, scalar.heads);
        expect(batch.entities, scalar.entities);
        expect(batch.anomalousEntities, scalar.anomalousEntities);
        for (final table in [
          'graph_node',
          'graph_head',
          'graph_redirect',
          'graph_relation',
        ]) {
          final left = await rig.database.rows(
            "SELECT * FROM $table WHERE run_id='scalar'",
          );
          final right = await rig.database.rows(
            "SELECT * FROM $table WHERE run_id='batch'",
          );
          List<String> normalized(dynamic rows) => [
            for (final row in rows)
              (Map<String, dynamic>.from(
                row.data,
              )..remove('run_id')).toString(),
          ]..sort();
          expect(normalized(right), normalized(left), reason: table);
        }
      } finally {
        await rig.database.close();
        await directory.delete(recursive: true);
      }
    });
  }

  for (final pageSize in [1, 7, 500]) {
    test(
      'standard ancestry through delete rejects historical put, page $pageSize',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'graph-standard-',
        );
        final rig = StorageTestRig(File('${directory.path}/source.sqlite'));
        try {
          final base = await fixture(1).toList();
          final quote = base[2];
          RevisionEnvelope next(
            String kind,
            Map<String, Object?> payload,
            List<String> parents,
          ) => RevisionEnvelope.create(
            entityType: quote.entityType,
            entityId: quote.entityId,
            parents: parents,
            kind: kind,
            payload: payload,
            authoredAt: quote.authoredAt,
            originDeviceId: quote.originDeviceId,
          );
          final historicalRoot = next('put', {
            ...quote.payload,
            'capture_mode': 'historical',
          }, []);
          final standard = next(
            'put',
            {...quote.payload, 'capture_mode': 'standard'},
            [historicalRoot.revisionId],
          );
          final deleted = next('delete', {}, [standard.revisionId]);
          final downgrade = next(
            'put',
            {...quote.payload, 'capture_mode': 'historical'},
            [deleted.revisionId],
          );
          await rig.database.createJob('job');
          for (final revision in [
            base[0],
            base[1],
            historicalRoot,
            standard,
            deleted,
            downgrade,
          ]) {
            await rig.database.appendStaging('job', revision);
          }
          await rig.database.sealJob('job', 'decisions');
          for (final work in [
            ScalarWorkspace(rig.database, jobId: 'job', runId: 'scalar'),
            SqlGraphWorkspace(rig.database, jobId: 'job', runId: 'batch'),
          ]) {
            await expectLater(
              RevisionGraphValidator(pageSize: pageSize).validate(work),
              throwsA(
                isA<DomainFailure>().having(
                  (error) => error.code,
                  'code',
                  'standard_downgrade',
                ),
              ),
            );
            expect(
              (await rig.database.rows(
                "SELECT state FROM graph_run WHERE run_id='${work.runId}'",
              )).single.read<String>('state'),
              'discarded',
            );
          }
        } finally {
          await rig.database.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }
}
