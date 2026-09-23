import 'package:supplier_core/src/contracts.dart';
import 'package:test/test.dart';

void main() {
  const version = DatabaseVersion(
    instanceId: 'db-a',
    activeEpoch: 3,
    generation: 9,
  );
  const token = PreviewToken(
    version: version,
    jobId: 'job',
    sealedStagingDigest: 'sealed',
    decisionsDigest: 'choices',
    schemaVersion: 2,
  );
  test('preview rejects recovered database with same generation', () {
    expect(
      token.matches(
        version: const DatabaseVersion(
          instanceId: 'db-b',
          activeEpoch: 3,
          generation: 9,
        ),
        jobId: 'job',
        sealedStagingDigest: 'sealed',
        decisionsDigest: 'choices',
      ),
      isFalse,
    );
  });
  test('preview binds every mutable input', () {
    expect(
      token.matches(
        version: version,
        jobId: 'job',
        sealedStagingDigest: 'sealed',
        decisionsDigest: 'choices',
      ),
      isTrue,
    );
    expect(
      token.matches(
        version: const DatabaseVersion(
          instanceId: 'db-a',
          activeEpoch: 4,
          generation: 9,
        ),
        jobId: 'job',
        sealedStagingDigest: 'sealed',
        decisionsDigest: 'choices',
      ),
      isFalse,
    );
    expect(
      token.matches(
        version: const DatabaseVersion(
          instanceId: 'db-a',
          activeEpoch: 3,
          generation: 10,
        ),
        jobId: 'job',
        sealedStagingDigest: 'sealed',
        decisionsDigest: 'choices',
      ),
      isFalse,
    );
    expect(
      token.matches(
        version: version,
        jobId: 'other',
        sealedStagingDigest: 'sealed',
        decisionsDigest: 'choices',
      ),
      isFalse,
    );
    expect(
      token.matches(
        version: version,
        jobId: 'job',
        sealedStagingDigest: 'changed',
        decisionsDigest: 'choices',
      ),
      isFalse,
    );
    expect(
      token.matches(
        version: version,
        jobId: 'job',
        sealedStagingDigest: 'sealed',
        decisionsDigest: 'changed',
      ),
      isFalse,
    );
    expect(
      token.matches(
        version: version,
        jobId: 'job',
        sealedStagingDigest: 'sealed',
        decisionsDigest: 'choices',
        schemaVersion: 3,
      ),
      isFalse,
    );
  });
  test('scan pages own an immutable bounded copy', () {
    final input = <int>[1, 2];
    final page = ScanPage(input, nextCursor: '2', limit: 2);
    input.add(3);
    expect(page.items, [1, 2]);
    expect(() => page.items.add(4), throwsUnsupportedError);
    expect(() => ScanPage([1, 2, 3], limit: 2), throwsArgumentError);
    expect(() => ScanPage<int>([], limit: 0), throwsArgumentError);
    expect(
      () => ScanPage<int>([], nextCursor: 'x', limit: 2),
      throwsArgumentError,
    );
  });
}
