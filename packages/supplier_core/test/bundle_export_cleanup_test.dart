import 'package:drift/drift.dart' show QueryExecutor, driftRuntimeOptions;
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'bundle_test.dart' show testBudget;

class FailingCloseExecutor implements QueryExecutor {
  final failure = StateError('validation-close');
  int closes = 0;
  @override
  Future<void> close() async {
    closes++;
    throw failure;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FailingSnapshot implements BundleSnapshot {
  FailingSnapshot(this.failure);
  final Object failure;
  final failureStack = StackTrace.current;
  int pages = 0;
  @override
  DatabaseVersion get version => const DatabaseVersion(
    instanceId: '11111111-1111-4111-8111-111111111111',
    activeEpoch: 1,
    generation: 0,
  );
  @override
  Future<void> assertFrozen() async {}
  @override
  Stream<BundleRow> page(String kind, {String? afterKey, required int limit}) {
    pages++;
    return Stream.error(failure, failureStack);
  }
}

class AbortOutput implements OutputTarget {
  int aborts = 0;
  @override
  Future<void> abort() async {
    aborts++;
  }

  @override
  Future<void> publish() async => fail('must not publish');
  @override
  Future<void> write(Stream<List<int>> bytes) async => fail('must not write');
}

void main() {
  // Each injected executor is independent and deliberately fails close.
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);
  for (final primary in <Object>[
    StateError('encoding-primary'),
    const DomainFailure('XLSX_VOLUME_LIMIT', 'retryable volume limit'),
  ]) {
    test('encoding and validation close failures survive: $primary', () async {
      final snapshot = FailingSnapshot(primary);
      final executor = FailingCloseExecutor();
      final output = AbortOutput();
      try {
        await exportBundle(
          snapshot: snapshot,
          columns: BundleColumns.schema2(),
          budget: testBudget,
          bundleId: '22222222-2222-4222-8222-222222222222',
          exportedAt: '2026-09-22T00:00:00.000Z',
          exporterVersion: 'test',
          createArtifact: () async =>
              throw StateError('must not create artifact'),
          createXlsxStaging: () async => XlsxStaging(executor),
          createBundleStaging: (_) async =>
              throw StateError('must not validate bundle'),
          target: output,
        );
        fail('must fail');
      } on DomainFailure catch (error) {
        expect(error.code, 'BUNDLE_CLEANUP_FAILED');
        final dynamic cause = error.cause;
        expect(cause.primary, same(primary));
        expect(cause.primaryStack, same(snapshot.failureStack));
        expect(cause.cleanup, same(executor.failure));
        expect(cause.cleanupStack, isA<StackTrace>());
      }
      expect(
        snapshot.pages,
        1,
        reason: 'cleanup failure must stop shrinking retries',
      );
      expect(executor.closes, 1);
      expect(output.aborts, 1);
    });
  }
}
