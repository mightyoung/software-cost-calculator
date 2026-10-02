import 'dart:io';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';
import 'support/test_rig.dart';

void main() {
  for (final pageSize in [1, 2, 500]) {
    final installPageSize = pageSize == 500 ? 3 : null;
    group('authority page size $pageSize install ${installPageSize ?? pageSize}', () {
      late Directory directory;
      late StorageTestRig rig;
      setUp(() async {
        directory = await Directory.systemTemp.createTemp('authority-batch-');
        rig = StorageTestRig(File('${directory.path}/data.sqlite'));
      });
      tearDown(() async {
        await rig.database.close();
        await directory.delete(recursive: true);
      });
      Future<CommitReceipt> commit(PreviewToken token, {CommitFault? fault}) =>
          CommitCoordinator(
            database: rig.database,
            writeLock: rig.lock,
            readActiveVersion: rig.active,
            pageSize: pageSize,
            installPageSize: installPageSize,
            fault: fault,
          ).commitStaged(
            jobId: token.jobId,
            expectedPreviewToken: token,
            confirmationEventId: 'event-${token.jobId}',
          );
      Future<int> count(String table) async => (await rig.database.rows(
        'SELECT COUNT(*) AS n FROM $table',
      )).single.read<int>('n');

      test(
        'parent edges across pages and duplicate import remain exact',
        () async {
          final root = fixtureRevision(0);
          final revisions = [root];
          for (var i = 1; i < 5; i++) {
            revisions.add(
              RevisionEnvelope.create(
                entityType: root.entityType,
                entityId: root.entityId,
                parents: [revisions.last.revisionId],
                kind: 'put',
                payload: {...root.payload, 'name': 'Version $i'},
                authoredAt: root.authoredAt,
                originDeviceId: root.originDeviceId,
              ),
            );
          }
          for (final id in ['chain', 'duplicate']) {
            await rig.database.createJob(id);
            for (final revision in revisions.reversed) {
              await rig.database.appendStaging(id, revision);
            }
            final token = await rig.database.sealJob(id, 'decisions');
            await rig.database.registerConfirmation('event-$id', token);
            expect((await commit(token)).resultCount, 5);
          }
          final edges = await rig.database.rows(
            'SELECT child_id,parent_id FROM revision_parent ORDER BY child_id,parent_id',
          );
          final expected = [
            for (final revision in revisions.skip(1))
              '${revision.revisionId}:${revision.parents.single}',
          ]..sort();
          expect(
            edges.map(
              (r) =>
                  '${r.read<String>('child_id')}:${r.read<String>('parent_id')}',
            ),
            expected,
          );
          expect(await count('revision'), 5);
          expect(await count('receipt_result'), 10);
          expect(await rig.database.rows('PRAGMA foreign_key_check'), isEmpty);
        },
      );

      test(
        'empty stage retains page zero fault and zero receipt count',
        () async {
          final points = <String>[];
          final receipt = await commit(
            await rig.stage(count: 0),
            fault: (point) async {
              points.add(point);
            },
          );
          expect(receipt.resultCount, 0);
          expect(points, ['page:0', 'before_commit', 'after_commit']);
          expect(await count('revision'), 0);
        },
      );

      test(
        'same canonical duplicates count staging rows and retain order',
        () async {
          await commit(await rig.stage(id: 'first', count: 5));
          final points = <String>[];
          final receipt = await commit(
            await rig.stage(id: 'second', count: 5),
            fault: (point) async {
              points.add(point);
            },
          );
          expect(receipt.resultCount, 5);
          expect(receipt.version.generation, 2);
          expect(await count('revision'), 5);
          expect(await count('receipt_result'), 10);
          expect(points.where((p) => p.startsWith('page:')).toList(), [
            for (
              var n = installPageSize ?? pageSize;
              n < 5;
              n += installPageSize ?? pageSize
            )
              'page:$n',
            'page:5',
          ]);
          final page = await rig.coordinator().receiptResults('event-second');
          final expected = [
            for (var i = 0; i < 5; i++) fixtureRevision(i).revisionId,
          ]..sort();
          expect(page.items, expected);
          expect(await rig.database.rows('PRAGMA foreign_key_check'), isEmpty);
        },
      );

      test(
        'canonical collision fails without authority or receipt changes',
        () async {
          final token = await rig.stage(count: 5);
          final original = fixtureRevision(0);
          final other = fixtureRevision(99);
          await rig.database.customStatement(
            'INSERT INTO entity_identity VALUES(?,?)',
            [other.entityType, other.entityId],
          );
          await rig.database
              .customStatement('INSERT INTO revision VALUES(?,?,?,?)', [
                original.revisionId,
                other.entityType,
                other.entityId,
                other.canonical,
              ]);
          await expectLater(
            commit(token),
            throwsA(
              isA<DomainFailure>().having(
                (e) => e.code,
                'code',
                'revision_collision',
              ),
            ),
          );
          expect(await count('revision'), 1);
          expect(await count('receipt_result'), 0);
          expect((await rig.database.currentVersion()).generation, 0);
        },
      );

      test('SQL failure inside page rolls back and retry succeeds', () async {
        final token = await rig.stage(count: 5);
        final ids = [for (var i = 0; i < 5; i++) fixtureRevision(i).revisionId]
          ..sort();
        await rig.database.customStatement(
          "CREATE TRIGGER fail_authority BEFORE INSERT ON receipt_result WHEN NEW.revision_id='${ids[1]}' BEGIN SELECT RAISE(ABORT,'injected mid-page failure'); END",
        );
        await expectLater(commit(token), throwsA(anything));
        for (final table in [
          'entity_identity',
          'revision',
          'receipt_result',
          'commit_receipt',
        ]) {
          expect(await count(table), 0, reason: table);
        }
        expect((await rig.database.currentVersion()).generation, 0);
        await rig.database.customStatement('DROP TRIGGER fail_authority');
        expect((await commit(token)).resultCount, 5);
      });

      test('response loss retry preserves receipt and generation', () async {
        final token = await rig.stage();
        await expectLater(
          commit(
            token,
            fault: (point) async {
              if (point == 'after_commit') {
                throw StateError('response lost');
              }
            },
          ),
          throwsStateError,
        );
        await rig.reopen();
        final receipt = await commit(token);
        expect(receipt.resultCount, 5);
        expect(receipt.version.generation, 1);
        expect(await count('commit_receipt'), 1);
        expect(await count('receipt_result'), 5);
      });

      test('malformed staged canonical cannot install authority', () async {
        final token = await rig.stage(count: 5);
        // Simulate persisted corruption beyond the normal seal guard.
        await rig.database.customStatement('DROP TRIGGER staging_seal_update');
        await rig.database.customStatement(
          'UPDATE staging_revision SET canonical=? WHERE revision_id=?',
          ['{invalid', fixtureRevision(0).revisionId],
        );
        await expectLater(commit(token), throwsA(anything));
        await rig.reopen();
        expect(await count('revision'), 0);
        expect(await count('receipt_result'), 0);
        expect((await rig.database.currentVersion()).generation, 0);
      });

      for (final failurePoint in ['page:${installPageSize ?? pageSize}']) {
        test('$failurePoint rollback survives reopen and retry', () async {
          final size = installPageSize ?? pageSize;
          final token = await rig.stage(count: size + 1);
          await expectLater(
            commit(
              token,
              fault: (point) async {
                if (point != failurePoint) return;
                expect(await count('receipt_result'), size);
                throw StateError('injected $point');
              },
            ),
            throwsStateError,
          );
          await rig.reopen();
          for (final table in [
            'entity_identity',
            'revision',
            'revision_parent',
            'receipt_result',
            'commit_receipt',
          ]) {
            expect(await count(table), 0, reason: table);
          }
          expect((await rig.database.currentVersion()).generation, 0);
          expect((await commit(token)).resultCount, size + 1);
          expect(await rig.database.rows('PRAGMA foreign_key_check'), isEmpty);
        });
      }
    });
  }
}
