import 'dart:convert';
import 'dart:io';
import 'package:supplier_core/src/contracts.dart';
import 'package:supplier_core/src/exchange/bundle_manifest.dart';
import 'package:supplier_core/src/exchange/bundle_import.dart';
import 'package:supplier_core/src/exchange/bundle_export.dart';
import 'package:supplier_core/src/exchange/projection_digest.dart';
import 'package:test/test.dart';

const testBudget = BundleBudget(
  compressedBytes: 32 * 1024 * 1024,
  expandedBytes: 128 * 1024 * 1024,
  revisions: 10000,
  volumes: 100,
);
const emptySha =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
BundleColumns testColumns() => BundleColumns({
  for (final kind in bundleKinds.skip(1)) kind: ['entity_id', 'name'],
});
BundleManifest testManifest() => BundleManifest(
  bundleId: '11111111-1111-4111-8111-111111111111',
  exportedAt: '2026-09-21T00:00:00.000Z',
  exporterVersion: 'test',
  revisionCount: 0,
  entityCounts: {for (final kind in bundleKinds.skip(1)) kind: 0},
  revisionsDigest: emptySha,
  businessDigest: emptySha,
  volumes: [
    for (final kind in bundleKinds)
      BundleVolume(
        kind: kind,
        index: 1,
        rowCount: 0,
        sha256: emptySha,
        compressedBytes: 22,
        expandedBytes: 1,
      ),
  ],
  budget: testBudget,
);

void main() {
  test('frozen release schema2 agrees with independent empty-table oracle', () {
    final vector =
        jsonDecode(
              File(
                'test/fixtures/v2/bundles/schema2-empty-digest.json',
              ).readAsStringSync(),
            )
            as Map;
    final digest = BundleDigests(BundleColumns.schema2());
    for (final kind in bundleKinds) {
      digest.beginKind(kind);
    }
    final result = digest.finish();
    expect(result.revisions, vector['revisions_digest']);
    expect(result.business, vector['business_digest']);
  });
  test('manifest is strict, roundtrips, and rejects future versions', () {
    final manifest = testManifest();
    expect(
      BundleManifest.decode(
        utf8.encode(manifest.encode()),
        testBudget,
      ).encode(),
      manifest.encode(),
    );
    final future = manifest.toJson()..['schema_version'] = 3;
    expect(
      () => BundleManifest.decode(utf8.encode(jsonEncode(future)), testBudget),
      throwsA(
        isA<DomainFailure>().having(
          (e) => e.code,
          'code',
          'UNSUPPORTED_FORMAT',
        ),
      ),
    );
  });
  test('duplicate decoded JSON keys and unknown fields are rejected', () {
    final text = testManifest().encode();
    expect(
      () => BundleManifest.decode(
        utf8.encode('{"bundle_id":"ignored",${text.substring(1)}'),
        testBudget,
      ),
      throwsA(isA<DomainFailure>()),
    );
    final unknown = testManifest().toJson()..['unknown'] = true;
    expect(
      () => BundleManifest.decode(utf8.encode(jsonEncode(unknown)), testBudget),
      throwsA(anything),
    );
    final escaped = text.replaceFirst(
      '"bundle_id":',
      '"bundle_\\u0069d":"duplicate","bundle_id":',
    );
    expect(
      () => BundleManifest.decode(utf8.encode(escaped), testBudget),
      throwsA(isA<DomainFailure>()),
    );
  });
  test('duplicate paths, missing tables and declared budgets are rejected', () {
    final raw = testManifest().toJson();
    final volumes = raw['volumes'] as List;
    volumes.add(volumes.first);
    expect(
      () => BundleManifest.decode(utf8.encode(jsonEncode(raw)), testBudget),
      throwsA(isA<DomainFailure>()),
    );
    final missing = testManifest().toJson();
    (missing['volumes'] as List).removeLast();
    expect(
      () => BundleManifest.decode(utf8.encode(jsonEncode(missing)), testBudget),
      throwsA(isA<DomainFailure>()),
    );
    expect(
      () => BundleManifest.decode(
        utf8.encode(testManifest().encode()),
        const BundleBudget(
          compressedBytes: 100,
          expandedBytes: 100,
          revisions: 1,
          volumes: 10,
        ),
      ),
      throwsA(isA<DomainFailure>()),
    );
  });
  test(
    'empty tables retain headers and agree with independent digest fixture',
    () {
      final vector =
          jsonDecode(
                File(
                  'test/fixtures/v2/bundles/digest-vector.json',
                ).readAsStringSync(),
              )
              as Map;
      final digest = BundleDigests(testColumns());
      for (final kind in bundleKinds) {
        digest.beginKind(kind);
      }
      final actual = digest.finish();
      expect(actual.revisions, vector['empty_revisions_digest']);
      expect(actual.business, vector['empty_business_digest']);
    },
  );
  test(
    'null differs from empty text and duplicate identities cannot cross volumes',
    () {
      String hash(String? value) {
        final digest = BundleDigests(testColumns());
        for (final kind in bundleKinds) {
          digest.beginKind(kind);
          if (kind == 'suppliers') digest.add(BundleRow('id', ['id', value]));
        }
        return digest.finish().business;
      }

      expect(hash(null), isNot(hash('')));
      final digest = BundleDigests(testColumns())
        ..beginKind('revisions')
        ..beginKind('suppliers');
      digest.add(BundleRow('id', ['id', 'supplier']));
      expect(
        () => digest.add(BundleRow('id', ['id', 'supplier'])),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test(
    'streaming STORE directory checks payload CRC and exact file set',
    () async {
      final manifest = testManifest();
      final files = [
        (
          path: 'manifest.json',
          source: TestBuffer(utf8.encode(manifest.encode())) as InputSource,
        ),
        for (final volume in manifest.volumes)
          (
            path: volume.path,
            source: TestBuffer(List.filled(22, 0)) as InputSource,
          ),
      ];
      final buffer = TestBuffer();
      await buffer.write(encodeBundleStore(files, testBudget));
      final archive = await BundleArchive.open(buffer, testBudget);
      expect((await archive.manifest(testBudget)).volumes.length, 5);
      await archive.entries['revisions-000001.xlsx']!.verifyCrc();
      final corrupted = TestBuffer(List.of(buffer.bytes));
      corrupted.bytes[archive.entries['revisions-000001.xlsx']!.start] ^= 1;
      final bad = await BundleArchive.open(corrupted, testBudget);
      await expectLater(
        bad.entries['revisions-000001.xlsx']!.verifyCrc(),
        throwsA(isA<DomainFailure>()),
      );
    },
  );
  test('missing final volume fails before any staging begins', () async {
    final manifest = testManifest();
    final files = [
      (
        path: 'manifest.json',
        source: TestBuffer(utf8.encode(manifest.encode())) as InputSource,
      ),
      for (final volume in manifest.volumes.take(4))
        (
          path: volume.path,
          source: TestBuffer(List.filled(22, 0)) as InputSource,
        ),
    ];
    final buffer = TestBuffer();
    await buffer.write(encodeBundleStore(files, testBudget));
    final archive = await BundleArchive.open(buffer, testBudget);
    await expectLater(
      archive.manifest(testBudget),
      throwsA(
        isA<DomainFailure>().having((e) => e.code, 'code', 'MISSING_VOLUME'),
      ),
    );
  });
  test(
    'cancel during streaming output produces no successful completed ZIP',
    () async {
      final buffer = TestBuffer();
      await expectLater(
        buffer.write(
          encodeBundleStore(
            [
              (
                path: 'manifest.json',
                source: TestBuffer(List.filled(100000, 0)) as InputSource,
              ),
            ],
            testBudget,
            checkpoint: () async =>
                throw const DomainFailure('CANCELLED', 'test'),
          ),
        ),
        throwsA(isA<DomainFailure>()),
      );
      expect(buffer.published, false);
    },
  );
}

/// Deliberately small in-memory test double; production adapters persist files.
class TestBuffer implements InputSource, OutputTarget {
  TestBuffer([List<int>? initial]) : bytes = initial ?? [];
  List<int> bytes;
  bool published = false, aborted = false;
  @override
  String get displayName => 'test.siq.zip';
  @override
  Future<int> length() async => bytes.length;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    yield bytes.sublist(start, endExclusive);
  }

  @override
  Future<void> write(Stream<List<int>> source) async {
    bytes = [];
    await for (final part in source) {
      bytes.addAll(part);
    }
  }

  @override
  Future<void> publish() async {
    published = true;
  }

  @override
  Future<void> abort() async {
    aborted = true;
    bytes = [];
  }
}
