import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

void main() {
  const version = DatabaseVersion(
    instanceId: 'test',
    activeEpoch: 1,
    generation: 2,
  );
  CapacitySample sample(int? bytes) => CapacitySample(
    status: bytes == null ? 'unsupported' : 'estimated',
    scope: 'test',
    availableBytes: bytes,
  );
  RestoreSpaceEstimate estimate(String phase, int? free) =>
      RestoreSpaceEstimate(
        version: version,
        phase: phase,
        capacity: sample(free),
        activeBytes: 100,
        candidateBytes: 300,
        sourceBytes: 200,
      );
  test(
    'prepare accounts for staging journals and two simultaneous backups',
    () {
      final value = estimate('prepare', null);
      expect(value.budget.components['staging'], 400);
      expect(value.budget.components['candidate_increment'], 800);
      expect(value.budget.components['transaction_journal'], 1200 + 1048576);
      expect(value.budget.components['safety_backup_private'], 200 + 1048576);
      expect(value.budget.components['safety_backup_published'], 200 + 1048576);
      expect(value.budget.fits, isNull);
      value.requireAvailable();
      expect(value.toJson()['policy'], 'restore-space-v1');
    },
  );
  test('activate never charges an already allocated candidate twice', () {
    final value = estimate('activate', null);
    expect(value.budget.components['candidate_increment'], 0);
    expect(value.budget.components['staging'], 0);
    expect(value.budget.components['transaction_journal'], 400 + 1048576);
  });
  test(
    'exactly enough is admitted and one byte short retains diagnostic budget',
    () {
      final needed = estimate('prepare', null).budget.estimatedBytes.toInt();
      estimate('prepare', needed).requireAvailable();
      expect(
        () => estimate('prepare', needed - 1).requireAvailable(),
        throwsA(
          isA<DomainFailure>()
              .having((e) => e.code, 'code', 'SPACE_REQUIRED')
              .having(
                (e) => (e.cause as Map)['policy'],
                'policy',
                'restore-space-v1',
              ),
        ),
      );
    },
  );
  test('multiplication checks exact integer range before conversion', () {
    expect(
      () => RestoreSpaceEstimate(
        version: version,
        phase: 'prepare',
        capacity: sample(null),
        activeBytes: 0,
        sourceBytes: 9007199254740991,
      ),
      throwsA(isA<DomainFailure>()),
    );
  });
  test('unknown cannot advertise a numeric available value', () {
    expect(
      () => CapacitySample(
        status: 'unsupported',
        scope: 'test',
        availableBytes: 0,
      ),
      throwsArgumentError,
    );
  });
}
