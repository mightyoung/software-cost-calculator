import 'dart:io';
import 'package:drift/drift.dart';
import 'package:supplier_core/src/contracts.dart';
import 'package:supplier_core/src/data/graph_workspace.dart';
import 'package:supplier_core/src/domain/revision.dart';
import 'package:supplier_core/src/domain/revision_graph.dart';
import 'package:test/test.dart';
import 'support/test_rig.dart';

class TerminalTestWorkspace extends SqlGraphWorkspace {
  TerminalTestWorkspace(
    super.database, {
    required super.jobId,
    required super.runId,
    required this.enabled,
    this.fault,
  });
  final bool enabled;
  final String? fault;
  bool? supported;
  @override
  Future<bool> supportsTerminalPages() async {
    if (fault != null) {
      final heads = await database.rows(
        'SELECT revision_id FROM graph_head WHERE run_id=? ORDER BY entity_type,entity_id',
        [Variable(runId)],
      );
      final missing = fault == 'missing-first' ? 0 : 1;
      final corrupt = fault == 'insert-first' ? 1 : 1 - missing;
      if (fault == 'insert-first') {
        await database.customStatement(
          "CREATE TRIGGER IF NOT EXISTS fail_terminal_insert BEFORE INSERT ON graph_relation BEGIN SELECT RAISE(ABORT,'injected terminal insert'); END",
        );
      } else {
        await database.customStatement(
          'DELETE FROM graph_head WHERE run_id=? AND revision_id=?',
          [runId, heads[missing].read<String>('revision_id')],
        );
      }
      await database.customStatement(
        'UPDATE graph_revision SET canonical=? WHERE run_id=? AND revision_id=?',
        [
          fixtureRevision(99).canonical,
          runId,
          heads[corrupt].read<String>('revision_id'),
        ],
      );
    }
    supported = enabled && await super.supportsTerminalPages();
    return supported!;
  }
}

RevisionEnvelope edit(
  RevisionEnvelope parent,
  int i, {
  String kind = 'put',
  String? target,
}) => RevisionEnvelope.create(
  entityType: parent.entityType,
  entityId: parent.entityId,
  parents: [parent.revisionId],
  kind: kind,
  payload: kind == 'redirect'
      ? {'target_id': target!}
      : kind == 'delete'
      ? {}
      : {...fixtureRevision(1).payload, 'notes': 'edit-$i'},
  authoredAt: parent.authoredAt,
  originDeviceId: parent.originDeviceId,
);

void main() {
  test('paged relation lookup preserves order and missing positions', () async {
    final dir = await Directory.systemTemp.createTemp('graph-relation-page-');
    final rig = StorageTestRig(File('${dir.path}/db.sqlite'));
    try {
      await rig.database.createJob('job');
      final first = fixtureRevision(1);
      final second = fixtureRevision(2);
      await rig.database.appendStaging('job', first);
      await rig.database.appendStaging('job', second);
      await rig.database.sealJob('job', 'decisions');
      final work = SqlGraphWorkspace(
        rig.database,
        jobId: 'job',
        runId: 'paged',
      );
      await RevisionGraphValidator(pageSize: 1).validate(work);
      final entities = [
        GraphEntity(second.entityType, second.entityId),
        const GraphEntity('supplier', 'missing'),
        GraphEntity(first.entityType, first.entityId),
      ];
      final relations = await work.relationsPage(entities);
      expect(relations.map((relation) => relation?.status).toList(), [
        GraphRelationStatus.active,
        null,
        GraphRelationStatus.active,
      ]);
      expect(relations.first?.canonical, entities.first);
      expect(relations.last?.canonical, entities.last);
    } finally {
      await rig.database.close();
      await dir.delete(recursive: true);
    }
  });

  for (final fault in ['missing-first', 'corrupt-first', 'insert-first']) {
    for (final pageSize in [1, 2, 7, 500]) {
      test('terminal error order $fault page $pageSize', () async {
        final dir = await Directory.systemTemp.createTemp(
          'graph-terminal-error-',
        );
        final rig = StorageTestRig(File('${dir.path}/db.sqlite'));
        try {
          await rig.database.createJob('job');
          for (var i = 1; i <= 2; i++) {
            await rig.database.appendStaging('job', fixtureRevision(i));
          }
          await rig.database.sealJob('job', 'decisions');
          for (final enabled in [false, true]) {
            final work = TerminalTestWorkspace(
              rig.database,
              jobId: 'job',
              runId: '$enabled',
              enabled: enabled,
              fault: fault,
            );
            await expectLater(
              RevisionGraphValidator(pageSize: pageSize).validate(work),
              fault == 'insert-first'
                  ? throwsA(
                      predicate(
                        (e) =>
                            e.toString().contains('injected terminal insert'),
                      ),
                    )
                  : throwsA(
                      isA<DomainFailure>().having(
                        (e) => e.code,
                        'code',
                        fault == 'missing-first'
                            ? 'graph_missing_head'
                            : 'revision_hash_mismatch',
                      ),
                    ),
            );
            expect(
              await rig.database.rows(
                'SELECT * FROM graph_relation WHERE run_id=?',
                [Variable(work.runId)],
              ),
              isEmpty,
            );
          }
        } finally {
          await rig.database.close();
          await dir.delete(recursive: true);
        }
      });
    }
  }
  for (final pageSize in [1, 2, 7, 500]) {
    for (final scenario in [
      'terminal',
      'current redirect',
      'historical redirect',
      'many heads',
    ]) {
      test('$scenario terminal differential page $pageSize', () async {
        final dir = await Directory.systemTemp.createTemp('graph-terminal-');
        final rig = StorageTestRig(File('${dir.path}/db.sqlite'));
        try {
          final a = fixtureRevision(1),
              b = fixtureRevision(2),
              c = fixtureRevision(3);
          final redirect = edit(a, 0, kind: 'redirect', target: b.entityId);
          final input = [
            a,
            b,
            c,
            edit(c, 0, kind: 'delete'),
            if (scenario == 'current redirect' ||
                scenario == 'historical redirect')
              redirect,
            if (scenario == 'historical redirect') edit(redirect, 1),
            if (scenario == 'many heads')
              for (var i = 0; i < 130; i++) edit(a, i),
          ];
          await rig.database.createJob('job');
          for (final revision in input) {
            await rig.database.appendStaging('job', revision);
          }
          await rig.database.sealJob('job', 'decisions');
          final scalar = TerminalTestWorkspace(
            rig.database,
            jobId: 'job',
            runId: 'scalar',
            enabled: false,
          );
          final batch = TerminalTestWorkspace(
            rig.database,
            jobId: 'job',
            runId: 'batch',
            enabled: true,
          );
          final x = await RevisionGraphValidator(
            pageSize: pageSize,
          ).validate(scalar);
          final y = await RevisionGraphValidator(
            pageSize: pageSize,
          ).validate(batch);
          expect(scalar.supported, false);
          expect(batch.supported, scenario != 'current redirect');
          expect(y.entities, x.entities);
          expect(y.heads, x.heads);
          expect(y.anomalousEntities, x.anomalousEntities);
          for (final entity in [a, b, c]) {
            final e = GraphEntity(entity.entityType, entity.entityId);
            final left = (await scalar.relation(e))!,
                right = (await batch.relation(e))!;
            expect(right.status, left.status);
            expect(right.canonical, left.canonical);
          }
        } finally {
          await rig.database.close();
          await dir.delete(recursive: true);
        }
      });
    }
  }
}
