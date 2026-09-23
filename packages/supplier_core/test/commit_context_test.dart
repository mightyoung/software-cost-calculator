import 'dart:io';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';
import 'support/test_rig.dart';

void main() {
  late Directory directory;
  late StorageTestRig rig;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'supplier-commit-context-',
    );
    rig = StorageTestRig(File('${directory.path}/business.sqlite'));
  });
  tearDown(() async {
    await rig.database.close();
    await directory.delete(recursive: true);
  });

  test(
    'held context commits and retries without reacquiring its lock',
    () async {
      final token = await rig.stage();
      await withApplicationWriteContext(rig.lock, (context) async {
        final coordinator = rig.coordinator();
        final first = await coordinator.commitStaged(
          jobId: token.jobId,
          expectedPreviewToken: token,
          confirmationEventId: 'event-job',
          context: context,
        );
        final retry = await coordinator.commitStaged(
          jobId: token.jobId,
          expectedPreviewToken: token,
          confirmationEventId: 'event-job',
          context: context,
        );
        expect(first.version.generation, 1);
        expect(retry.version.generation, 1);
        expect(rig.lock.held, isTrue);
      }).timeout(const Duration(seconds: 10));
      expect(rig.lock.held, isFalse);
    },
  );

  test('expired or different-lock contexts cannot commit', () async {
    final token = await rig.stage();
    late ApplicationWriteContext expired;
    await withApplicationWriteContext(rig.lock, (context) async {
      expired = context;
    });
    Future<CommitReceipt> commit(ApplicationWriteContext context) =>
        rig.coordinator().commitStaged(
          jobId: token.jobId,
          expectedPreviewToken: token,
          confirmationEventId: 'event-job',
          context: context,
        );
    await expectLater(commit(expired), throwsStateError);
    await withApplicationWriteContext(TestWriteLock(), (context) async {
      await expectLater(commit(context), throwsStateError);
    });
    expect((await rig.database.currentVersion()).generation, 0);
    expect(await rig.coordinator().findCommittedEvent('event-job'), isNull);
  });
}
