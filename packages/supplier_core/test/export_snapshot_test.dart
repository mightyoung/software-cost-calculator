import 'package:drift/native.dart';
import 'package:supplier_core/src/application/backup_service.dart';
import 'package:supplier_core/src/contracts.dart';
import 'package:supplier_core/src/domain/revision.dart';
import 'package:supplier_core/src/exchange/bundle_export.dart';
import 'package:supplier_core/src/exchange/bundle_import.dart';
import 'package:supplier_core/src/exchange/bundle_manifest.dart';
import 'package:supplier_core/src/exchange/projection_digest.dart';
import 'package:supplier_core/src/exchange/xlsx_staging.dart';
import 'package:test/test.dart';
import 'bundle_test.dart' show TestBuffer, testBudget, testColumns;
import 'support/test_rig.dart' show fixtureRevision;

void main() {
  Future<BundleManifest> run(
    _Snapshot snapshot,
    TestBuffer output, {
    bool rejectClosure = false,
    Future<void> Function()? checkpoint,
  }) => exportBundle(
    snapshot: snapshot,
    columns: testColumns(),
    budget: testBudget,
    bundleId: '11111111-1111-4111-8111-111111111111',
    exportedAt: '2026-09-21T00:00:00.000Z',
    exporterVersion: 'test',
    createArtifact: () async => _Artifact(),
    createXlsxStaging: () async => XlsxStaging(NativeDatabase.memory()),
    createBundleStaging: (version) async =>
        _Staging(version, rejectClosure: rejectClosure),
    target: output,
    rowsPerVolume: 1,
    checkpoint: checkpoint,
  );

  test(
    'all volumes use a frozen snapshot while unrelated live data changes',
    () async {
      final snapshot = _Snapshot(), output = TestBuffer();
      var simulatedLiveGeneration = 1;
      final manifest = await run(
        snapshot,
        output,
        checkpoint: () async {
          simulatedLiveGeneration++;
        },
      );
      expect(simulatedLiveGeneration, greaterThan(1));
      expect(snapshot.version.generation, 1);
      expect(manifest.revisionCount, 2);
      expect(manifest.volumes.where((v) => v.kind == 'revisions').length, 2);
      expect(manifest.entityCounts['suppliers'], 2);
      expect(output.published, true);
      expect(output.aborted, false);
      final parsed = _Staging(snapshot.version);
      final prepared = await prepareBundle(
        source: output,
        budget: testBudget,
        columns: testColumns(),
        staging: parsed,
        createXlsxStaging: () async => XlsxStaging(NativeDatabase.memory()),
      );
      expect(prepared.manifest.encode(), manifest.encode());
      expect(parsed.verified, true);
      expect(parsed.sealed, true);
    },
  );
  test('changed snapshot cannot be relabelled with a new generation', () async {
    final snapshot = _Snapshot(), output = TestBuffer();
    var checks = 0;
    await expectLater(
      run(
        snapshot,
        output,
        checkpoint: () async {
          if (++checks == 5) snapshot.changed = true;
        },
      ),
      throwsA(isA<DomainFailure>()),
    );
    expect(output.published, false);
    expect(output.aborted, true);
  });
  test(
    'failed complete closure or projection check prevents publication',
    () async {
      final output = TestBuffer();
      await expectLater(
        run(_Snapshot(), output, rejectClosure: true),
        throwsA(
          isA<DomainFailure>().having(
            (e) => e.code,
            'code',
            'TEST_GRAPH_REJECTED',
          ),
        ),
      );
      expect(output.published, false);
      expect(output.aborted, true);
    },
  );
  test(
    'cancelled export aborts target and exposes no partial package',
    () async {
      final output = TestBuffer();
      var checks = 0;
      await expectLater(
        run(
          _Snapshot(),
          output,
          checkpoint: () async {
            if (++checks == 12) {
              throw const DomainFailure('CANCELLED', 'cancelled');
            }
          },
        ),
        throwsA(isA<DomainFailure>()),
      );
      expect(output.published, false);
      expect(output.aborted, true);
    },
  );
}

class _Artifact implements BackupArtifact {
  final buffer = TestBuffer();
  @override
  InputSource get source => buffer;
  @override
  OutputTarget get output => buffer;
  @override
  Future<void> dispose() async {
    buffer.bytes = [];
  }
}

/// Small deterministic fixture only; real adapters must provide DB keyset pages.
class _Snapshot implements BundleSnapshot {
  final revisions = [fixtureRevision(1), fixtureRevision(2)]
    ..sort((a, b) => a.revisionId.compareTo(b.revisionId));
  bool changed = false;
  @override
  DatabaseVersion get version => DatabaseVersion(
    instanceId: '11111111-1111-4111-8111-111111111111',
    activeEpoch: 1,
    generation: changed ? 2 : 1,
  );
  @override
  Future<void> assertFrozen() async {
    if (changed) throw const DomainFailure('SNAPSHOT_CHANGED', 'test');
  }

  @override
  Stream<BundleRow> page(
    String kind, {
    String? afterKey,
    required int limit,
  }) async* {
    final rows = <BundleRow>[];
    if (kind == 'revisions') {
      for (final r in revisions) {
        rows.add(
          BundleRow(r.revisionId, [
            r.revisionId,
            r.entityType,
            r.entityId,
            r.canonical,
          ]),
        );
      }
    } else if (kind == 'suppliers') {
      for (final r in revisions) {
        rows.add(
          BundleRow(r.entityId, [r.entityId, r.payload['name'] as String]),
        );
      }
    }
    rows.sort((a, b) => a.key.compareTo(b.key));
    for (final row
        in rows
            .where((r) => afterKey == null || r.key.compareTo(afterKey) > 0)
            .take(limit)) {
      yield row;
    }
  }
}

/// Test-only independent check for the fixture's two root supplier graph. This
/// does not claim the production graph/union/commit adapter has been supplied.
class _Staging implements BundleStaging {
  _Staging(this.boundVersion, {this.rejectClosure = false});
  @override
  final DatabaseVersion boundVersion;
  final bool rejectClosure;
  final rows = <String, List<BundleRow>>{};
  bool verified = false, sealed = false;
  @override
  Future<void> begin(BundleManifest manifest) async {}
  @override
  Future<void> append(
    String kind,
    BundleRow row, {
    required String path,
    required int rowNumber,
  }) async {
    rows.putIfAbsent(kind, () => []).add(row);
  }

  @override
  Future<void> verifyClosureAndProjection(
    BundleManifest manifest,
    BundleColumns columns,
  ) async {
    if (rejectClosure) {
      throw const DomainFailure('TEST_GRAPH_REJECTED', 'injected');
    }
    final roots = <String, String>{};
    for (final row in rows['revisions'] ?? <BundleRow>[]) {
      final revision = RevisionEnvelope.fromCanonicalJson(row.cells[3]!);
      if (revision.parents.isNotEmpty ||
          revision.entityType != 'supplier' ||
          roots.containsKey(revision.entityId)) {
        throw StateError('Unexpected fixture graph');
      }
      roots[revision.entityId] = revision.payload['name'] as String;
    }
    final projections = rows['suppliers'] ?? <BundleRow>[];
    if (projections.length != roots.length) {
      throw StateError('Projection count differs');
    }
    for (final row in projections) {
      if (roots[row.key] != row.cells[1]) {
        throw StateError('Projection differs');
      }
    }
    verified = true;
  }

  @override
  Future<void> seal(String sourceDigest) async {
    if (!verified) throw StateError('Not verified');
    sealed = true;
  }

  @override
  Future<void> discard() async {
    rows.clear();
    sealed = false;
  }
}
