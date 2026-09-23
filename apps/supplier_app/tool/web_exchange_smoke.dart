import 'dart:convert';
import 'dart:js_interop';

import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_app/platform/web_database_host.dart';
import 'package:supplier_app/platform/web_file_ports.dart';
import 'package:supplier_app/platform/web_business_import.dart';
import 'package:supplier_app/platform/web_bundle_workflow.dart';
import 'package:supplier_app/platform/business_import_workflow_adapter.dart';

@JS('exchangeSmoke')
external set entry(JSFunction value);
@JS('probeReady')
external set ready(JSBoolean value);
@JS('exchangeStage')
external set stage(JSString value);
void check(bool value, String message) {
  if (!value) throw StateError(message);
}

String get base => Uri.base.queryParameters['run']!;
BackupService backups(WebDatabaseHost h) => BackupService(
  database: h.database,
  writeLock: h.lock,
  readActiveVersion: h.readActiveVersion,
  createArtifact: () => WebBackupArtifact.create(h.namespace),
);
WebBusinessImport business(WebDatabaseHost h) => WebBusinessImport(
  namespace: h.namespace,
  deviceId: h.deviceId,
  exchange: ExchangeService(
    coordinator: h.coordinator,
    backups: backups(h),
    createBackupDestination: () async {
      final b = await WebDurableBackup.create(h.namespace);
      return BusinessBackupDestination(
        b.output,
        b.source,
        onVerified: b.associateWithJob,
      );
    },
  ),
);
WebBundleWorkflow bundle(WebDatabaseHost h) => WebBundleWorkflow(
  namespace: h.namespace,
  backups: backups(h),
  budget: const BundleBudget(
    compressedBytes: 32 * 1024 * 1024,
    expandedBytes: 64 * 1024 * 1024,
    revisions: 1000,
    volumes: 100,
  ),
  exchange: BundleExchangeService(
    coordinator: h.coordinator,
    backups: backups(h),
    createBackupDestination: () async {
      final b = await WebDurableBackup.create(h.namespace);
      return BundleBackupDestination(
        b.output,
        b.source,
        onVerified: b.associateWithJob,
      );
    },
  ),
);
Future<int> count(WebDatabaseHost h, String table) async =>
    (await h.database.rows('SELECT COUNT(*) n FROM $table')).single
        .read<int>('n');
Future<Map<String, Object?>> run(String operation) async {
  final h = await WebDatabaseHost.open(namespace: '$base-business');
  try {
    if (operation == 'prepare') {
      final supplier = await h.records.createEntity('supplier', {
        'name': '浏览器供应商',
        'aliases': <String>[],
        'categories': <String>[],
        'address': null,
        'notes': null,
      });
      final product = await h.records.createEntity('product', {
        'name': '螺栓',
        'unit': '件',
        'brand': null,
        'model': '0001',
        'specification': null,
        'category': null,
        'notes': null,
      });
      final adapter = business(h);
      final validation = await adapter.openStaging('writer', existing: false);
      final file = await WebDurableBackup.create(h.namespace);
      const headers = [
        'supplier_id',
        'product_id',
        'price',
        'unit_snapshot',
        'quoted_on',
        'inquiry_date',
        'inquiry_precision',
        'project_name',
        'inquirer_name',
      ];
      try {
        final volume = await const BoundedXlsxWriter().encodeVolume(
          headers: headers,
          rows: Stream.fromIterable([
            [
              supplier,
              product,
              '32.123456',
              '件',
              '2026-09-23',
              '2026-09-23',
              'date',
              '采购',
              '李工',
            ],
          ]),
          validation: validation,
        );
        await volume.publishTo(file.output);
      } finally {
        await validation.close();
      }
      final sheets = await const BoundedXlsxReader().sheetNames(file.source);
      final selection = BusinessImportSelection(file.source, sheets);
      stage = 'business cancel prepare'.toJS;
      final cancelled = await adapter.prepare(selection, sheets.single);
      await cancelled.cancel();
      await cancelled.close();
      check(
        await count(h, 'import_row_receipt') == 0,
        'Cancel wrote import receipt',
      );
      stage = 'business prepare'.toJS;
      final session = await adapter.prepare(selection, sheets.single);
      await session.setMapping(
        BusinessMapping(
          columns: {
            for (var i = 0; i < headers.length; i++)
              headers[i]: BusinessColumnMapping(
                i + 1,
                BusinessMapping.conversionFor(headers[i]),
              ),
          },
        ),
      );
      await session.workflow.decide(
        2,
        BusinessRowDecision(
          choice: BusinessRowChoice.newInquiry,
          bindings: {'supplier_id': supplier, 'product_id': product},
        ),
      );
      stage = 'business commit'.toJS;
      final receipt = await session.confirm();
      final job = session.jobId;
      await session.close();
      await h.installation.compareAndSet(
        expected: {'smoke': null},
        changes: {
          'smoke': {'job': job, 'event': receipt.confirmationEventId},
        },
      );
      check(
        await count(h, 'quotation_projection') == 1,
        'Business import missing',
      );
      final target = await WebDatabaseHost.open(namespace: '$base-bundle');
      final output = await WebDurableBackup.create(h.namespace);
      try {
        stage = 'bundle export'.toJS;
        await bundle(h).export(output.output);
        final flow = bundle(target);
        stage = 'bundle cancelled preview'.toJS;
        final cancel = await flow.prepare(output.source);
        await flow.cancel(cancel);
        check(
          await count(target, 'revision') == 0 &&
              await count(target, 'commit_receipt') == 0,
          'Cancelled bundle wrote data',
        );
        stage = 'bundle prepare'.toJS;
        final preview = await flow.prepare(output.source);
        stage = 'bundle commit'.toJS;
        final imported = await flow.commit(preview);
        await target.installation.compareAndSet(
          expected: {'smoke': null},
          changes: {
            'smoke': {
              'job': preview.jobId,
              'event': imported.confirmationEventId,
            },
          },
        );
        check(
          await count(target, 'quotation_projection') == 1,
          'Bundle import missing',
        );
        final bad = await WebDurableBackup.create(target.namespace);
        await bad.output.write(Stream.value([1, 2, 3]));
        await bad.output.publish();
        final before = await count(target, 'commit_receipt');
        var failed = false;
        try {
          await flow.prepare(bad.source);
        } catch (_) {
          failed = true;
        }
        check(
          failed && await count(target, 'commit_receipt') == before,
          'Malformed bundle produced receipt',
        );
        return {
          'business': true,
          'bundle': true,
          'cancel_no_receipt': true,
          'malformed_no_receipt': true,
          'business_job': job,
          'bundle_job': preview.jobId,
          'input_boundary': 'real OPFS files; native chooser bypassed',
        };
      } finally {
        await target.close();
      }
    }
    if (operation == 'reopen') {
      final result = <String, Object?>{};
      for (final kind in ['business', 'bundle']) {
        final host = kind == 'business'
            ? h
            : await WebDatabaseHost.open(namespace: '$base-bundle');
        try {
          final saved = (await host.installation.read('smoke'))!;
          final job = saved['job']! as String;
          final locator = (await host.installation.read('import_backup:$job'))!;
          final decoded = await decodeBackup(
            await WebDurableBackup.read(
              host.namespace,
              locator['locator']! as String,
            ),
          );
          check(
            decoded.header.counts['revision'] == (kind == 'business' ? 2 : 0),
            'Backup not precommit image',
          );
          check(
            await count(host, 'quotation_projection') == 1,
            'Restart lost imported quotation',
          );
          if (kind == 'business') {
            final session = await business(host).resume(job);
            try {
              check(
                (await session.confirm()).confirmationEventId == saved['event'],
                'Retry receipt changed',
              );
            } finally {
              await session.close();
            }
          } else {
            final flow = bundle(host);
            check(
              (await flow.commit(await flow.resume(job))).confirmationEventId ==
                  saved['event'],
              'Bundle retry changed',
            );
          }
          result[kind] = {
            'locator_readable': true,
            'precommit_revisions': decoded.header.counts['revision'],
            'retry_same_receipt': true,
            'quotation_count': 1,
          };
        } finally {
          if (kind != 'business') await host.close();
        }
      }
      return result;
    }
    throw ArgumentError(operation);
  } finally {
    await h.close();
  }
}

void main() {
  entry =
      ((JSString op) => run(op.toDart)
              .then(
                (r) => jsonEncode(r).toJS,
                onError: (Object e, StackTrace s) =>
                    jsonEncode({'failure': '$e', 'stack': '$s'}).toJS,
              )
              .toJS)
          .toJS;
  ready = true.toJS;
}
