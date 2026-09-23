import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_app/platform/import_cancellation.dart';
import 'package:supplier_app/platform/business_import_workflow_adapter.dart';

import 'support/cancelling_source.dart';

import 'support/business_import_rig.dart';

void main() {
  late BusinessImportRig rig;
  setUp(() async {
    rig = await BusinessImportRig.open();
  });
  tearDown(() async {
    await rig.dispose();
  });
  test('business parse cancels during source fingerprint without business writes', () async {
    final selected = await rig.adapter.select(rig.filePath);
    final cancellation = ImportCancellation();
    final version = await rig.host.database.currentVersion();
    await expectLater(
      rig.adapter.prepare(
        BusinessImportSelection(
          CancellingSource(selected.source, cancellation),
          selected.sheets,
        ),
        selected.sheets.single,
        cancellation: cancellation,
      ),
      throwsA(isA<DomainFailure>()),
    );
    expect(
      (await rig.host.database.currentVersion()).generation,
      version.generation,
    );
    expect(
      (await QueryRepository(rig.host.database).quotations({})).items,
      isEmpty,
    );
    final jobs = await rig.host.database.rows(
      "SELECT j.state FROM import_job j JOIN job_input i ON i.job_id=j.job_id",
    );
    expect(jobs.single.read<String>('state'), 'cancelled');
  });
  test('native file selection, durable mapping/decision, reopen and confirmation retry use real services', () async {
    final selected = await rig.adapter.select(rig.filePath);
    expect(selected.sheets, hasLength(1));
    final session = await rig.adapter.prepare(selected, selected.sheets.single);
    await session.setMapping(
      BusinessMapping(
        columns: {
          for (final e in <String, int>{
            'supplier_id': 1,
            'product_id': 2,
            'price': 3,
            'unit_snapshot': 4,
            'quoted_on': 5,
            'inquiry_date': 6,
            'inquiry_precision': 7,
            'project_name': 8,
            'inquirer_name': 9,
            'notes': 10,
          }.entries)
            e.key: BusinessColumnMapping(
              e.value,
              BusinessMapping.conversionFor(e.key),
            ),
        },
      ),
    );
    final preview = (await session.workflow.previewPage()).single;
    expect(preview.mapped.values['price'], '32.123456');
    await session.workflow.decide(
      2,
      BusinessRowDecision(
        choice: BusinessRowChoice.newInquiry,
        bindings: {'supplier_id': rig.supplier, 'product_id': rig.product},
      ),
    );
    expect((await session.summary()).results, 1);
    expect(
      (await QueryRepository(rig.host.database).quotations({})).items,
      isEmpty,
    );
    final id = session.jobId;
    await session.close();
    await rig.reopen();
    final resumed = await rig.adapter.resume(id);
    expect(await resumed.workflow.decisionForRow(2), isNotNull);
    final first = await resumed.confirm();
    await resumed.close();
    await rig.reopen();
    final completed = await rig.adapter.resume(id);
    expect(completed.jobState, JobState.committed);
    final retry = await completed.confirm();
    expect(retry.confirmationEventId, first.confirmationEventId);
    final rows = await QueryRepository(rig.host.database).quotations({});
    expect(rows.items, hasLength(1));
    expect(rows.items.single.payload!['price'], '32.123456');
    await completed.close();
  });
  test('cancelled prepared task cannot commit and leaves business library untouched', () async {
    final selected = await rig.adapter.select(rig.filePath);
    final session = await rig.adapter.prepare(selected, selected.sheets.single);
    await session.cancel();
    expect(session.jobState, JobState.cancelled);
    await expectLater(
      rig.adapter.resume(session.jobId),
      throwsA(isA<DomainFailure>()),
    );
    expect(
      (await QueryRepository(rig.host.database).quotations({})).items,
      isEmpty,
    );
    await session.close();
  });
}
