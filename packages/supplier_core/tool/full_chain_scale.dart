/// Host-only A15 full-chain evidence using real commit/backup/bundle services.
/// Run from packages/supplier_core. Outputs must be a NEW directory.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
import '../test/support/test_rig.dart' show TestWriteLock;
import 'run_benchmarks.dart' show RollingDigest;

const sourceId = '00000000-0000-4000-8000-000000000001';
const restoredId = '00000000-0000-4000-8000-000000000002';
const supplierId = '10000000-0000-4000-8000-000000000001';
const productId = '20000000-0000-4000-8000-000000000001';
const authored = '2026-09-23T00:00:00.000Z';

/// Admission for the first stage only. Subsequent stages measure existing
/// files and reserve their own incremental working set plus 20%, so already
/// allocated files are not charged against free capacity twice.
int estimatedMainBytes(int count) =>
    (count * 32 * 1024).clamp(32 * 1024 * 1024, 1 << 50);
int requiredSpace(int count) => (estimatedMainBytes(count) * 3 * 1.2).ceil();

Future<int> availableSpace(Directory directory) async {
  final result = await Process.run('df', ['-Pk', directory.absolute.path]);
  final lines = result.stdout.toString().trim().split('\n');
  final fields = lines.last.trim().split(RegExp(r'\s+'));
  if (result.exitCode != 0 ||
      fields.length < 6 ||
      int.tryParse(fields[3]) == null) {
    throw const DomainFailure(
      'FULL_CHAIN_SPACE_BLOCKED',
      'Cannot measure capacity',
    );
  }
  return int.parse(fields[3]) * 1024;
}

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  for (final arg in args) {
    final at = arg.indexOf('=');
    if (!arg.startsWith('--') || at < 3) {
      throw ArgumentError('Use --count=N --out=NEW_DIR --rows-per-volume=N');
    }
    options[arg.substring(2, at)] = arg.substring(at + 1);
  }
  final count = int.parse(options['count'] ?? '100');
  final volume = int.parse(options['rows-per-volume'] ?? '5000');
  if (count < 1 || count > 100000 || volume < 1 || volume > 5000) {
    throw ArgumentError('count 1..100000, rows-per-volume 1..5000');
  }
  final out = Directory(options['out'] ?? 'full-chain-$count');
  if (await out.exists()) throw ArgumentError('Output must be a new directory');
  await out.create(recursive: true);
  final watch = Stopwatch()..start();
  final report = <String, Object?>{
    'schema': 1,
    'kind': 'formal-full-chain',
    'count': count,
    'expected_revisions': count * 5,
    'rows_per_volume': volume,
    'command': [
      Platform.resolvedExecutable,
      Platform.script.toFilePath(),
      ...args,
    ],
    'started_at': DateTime.now().toUtc().toIso8601String(),
    'environment': {
      'dart': Platform.version,
      'os': Platform.operatingSystemVersion,
    },
    'source_sha256': await sourceHashes(),
    'scope':
        'Native host; formal staged commit, backup, isolated restore, frozen multi-volume export and reopen digest',
    'unverified': [
      'Android/Windows deferred by user',
      'restore active-pointer publication',
      'A17 concurrent business edits at first/middle/last volume and cancellation',
      'I02 500k single entity history and changing scan barriers',
      'Web page/worker/WASM total memory',
    ],
  };
  try {
    report['space_budget'] = {
      'required_bytes': requiredSpace(count),
      'available_bytes': await availableSpace(out),
    };
    if (await availableSpace(out) < requiredSpace(count)) {
      throw const DomainFailure(
        'FULL_CHAIN_SPACE_BLOCKED',
        'Insufficient space for full-chain working set and reserve',
      );
    }
    report['result'] = await runFullChain(
      out,
      count: count,
      rowsPerVolume: volume,
    );
    report['status'] = 'PASS';
  } catch (error, stack) {
    report['status'] =
        error is DomainFailure && error.code == 'FULL_CHAIN_SPACE_BLOCKED'
        ? 'BLOCKED'
        : 'FAIL';
    report['error'] = error.toString();
    await File('${out.path}/failure.txt').writeAsString('$error\n$stack');
    exitCode = 1;
  } finally {
    report['elapsed_ms'] = watch.elapsedMilliseconds;
    report['process_peak_rss_bytes'] = ProcessInfo.maxRss;
    report['rss_scope'] =
        'Whole Dart process high water including fixture, SQLite, ZIP/XLSX, restore and verification';
    report['source_sha256_at_finish'] = await sourceHashes();
    if (jsonEncode(report['source_sha256']) !=
        jsonEncode(report['source_sha256_at_finish'])) {
      report['status'] = 'FAIL';
      report['error'] = 'Source files changed during measurement';
      exitCode = 1;
    }
    await File(
      '${out.path}/report.json',
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
    stdout.writeln('${report['status']}: ${out.path}/report.json');
  }
}

Future<Map<String, String>> sourceHashes() async {
  final paths = <String>[
    'pubspec.lock',
    'tool/full_chain_scale.dart',
    'tool/run_benchmarks.dart',
    'test/support/test_rig.dart',
  ];
  await for (final entry in Directory('lib').list(recursive: true)) {
    if (entry is File && entry.path.endsWith('.dart')) paths.add(entry.path);
  }
  paths.sort();
  return {
    for (final path in paths)
      path: (await sha256.bind(File(path).openRead()).single).toString(),
  };
}

/// Retains at most one quotation's five revisions while generating staging.
/// Exactly 5*count revisions: supplier+product, three revisions for first quote,
/// five for all remaining quotes. Shared references are valid and dense.
Stream<RevisionEnvelope> fixture(int count) async* {
  RevisionEnvelope revision(
    String type,
    String id,
    Map<String, Object?> payload, [
    String? parent,
  ]) => RevisionEnvelope.create(
    entityType: type,
    entityId: id,
    parents: parent == null ? [] : [parent],
    kind: 'put',
    payload: payload,
    authoredAt: authored,
    originDeviceId: sourceId,
  );
  yield revision('supplier', supplierId, {
    'name': 'Scale supplier',
    'notes': null,
    'aliases': <String>[],
    'categories': <String>[],
    'address': null,
  });
  yield revision('product', productId, {
    'name': 'Scale product',
    'unit': '件',
    'brand': null,
    'model': null,
    'specification': null,
    'category': null,
    'notes': null,
  });
  for (var i = 0; i < count; i++) {
    String? parent;
    final id = '30000000-0000-4000-8000-${i.toString().padLeft(12, '0')}';
    for (var depth = 0; depth < (i == 0 ? 3 : 5); depth++) {
      final value = revision('quotation', id, {
        'supplier_id': supplierId,
        'product_id': productId,
        'price': '${i + 1}.${depth + 1}',
        'currency': 'CNY',
        'tax_mode': 'unknown',
        'unit_snapshot': '件',
        'min_qty': '1',
        'quoted_on': '2026-09-23',
        'contact_id': null,
        'contact_snapshot': null,
        'tax_rate': null,
        'lead_time_days': null,
        'valid_until': null,
        'notes': 'quotation $i revision $depth',
        'project_name': '规模验收',
        'project_number': 'SCALE',
        'inquiry_location': null,
        'inquirer_name': 'tester',
        'inquiry_precision': 'date',
        'inquiry_date': '2026-09-23',
        'inquired_at': null,
        'inquiry_utc_offset_minutes': null,
        'capture_mode': 'standard',
      }, parent);
      yield value;
      parent = value.revisionId;
    }
  }
}

Future<Map<String, Object?>> runFullChain(
  Directory out, {
  required int count,
  int rowsPerVolume = 5000,
}) async {
  final resources = _Resources(out);
  final source = resources.database('source', sourceId);
  final lock = TestWriteLock();
  final timings = <String, int>{};
  final stageRss = <String, int>{};
  final stageSizes = <String, int>{};
  final spaceChecks = <String, Object?>{};
  final estimated = estimatedMainBytes(count);
  final compressedBudget = estimated.clamp(
    32 * 1024 * 1024,
    1024 * 1024 * 1024,
  );
  Future<T> measure<T>(String phase, Future<T> Function() action) async {
    final sourceFile = File('${out.path}/source.sqlite');
    final actualMain = await sourceFile.exists()
        ? await sourceFile.length()
        : 0;
    final mainBound = actualMain > estimated ? actualMain : estimated;
    final incremental = switch (phase) {
      'formal_fixture_commit' => estimated * 3,
      'backup' => mainBound * 2,
      'restore_candidate' => mainBound * 3,
      'bundle_export_and_self_verify' =>
        mainBound * 3 + compressedBudget * 3 + 256 * 1024 * 1024,
      _ => 32 * 1024 * 1024,
    };
    final available = await availableSpace(out);
    final required = (incremental * 1.2).ceil();
    spaceChecks[phase] = {
      'actual_source_main_bytes': actualMain,
      'estimated_main_bound_bytes': mainBound,
      'incremental_working_bytes': incremental,
      'required_free_bytes': required,
      'available_free_bytes': available,
    };
    await File(
      '${out.path}/space-checks.json',
    ).writeAsString(jsonEncode(spaceChecks));
    if (available < required) {
      throw DomainFailure(
        'FULL_CHAIN_SPACE_BLOCKED',
        '$phase requires $required free bytes, found $available',
      );
    }
    resources.reserveBytes = (incremental * .2).ceil();
    stdout.writeln('phase=$phase');
    final timer = Stopwatch()..start();
    final progress = Timer.periodic(const Duration(seconds: 30), (_) {
      stdout.writeln(
        'phase=$phase elapsed_ms=${timer.elapsedMilliseconds} rss_bytes=${ProcessInfo.currentRss}',
      );
    });
    late T result;
    try {
      result = await action();
    } finally {
      progress.cancel();
    }
    timings[phase] = timer.elapsedMilliseconds;
    stageRss[phase] = ProcessInfo.maxRss;
    var bytes = 0;
    await for (final file in out.list(recursive: true, followLinks: false)) {
      if (file is File) bytes += await file.length();
    }
    stageSizes[phase] = bytes;
    return result;
  }

  try {
    await measure('formal_fixture_commit', () async {
      await source.createJob('scale-fixture');
      final batch = <RevisionEnvelope>[];
      var staged = 0;
      Future<void> flush() => source.transaction(() async {
        for (final revision in batch) {
          await source.appendStaging('scale-fixture', revision);
        }
      });
      await for (final revision in fixture(count)) {
        batch.add(revision);
        staged++;
        if (batch.length == 200) {
          await flush();
          batch.clear();
          if (staged % 10000 == 0) {
            stdout.writeln('staged_revisions=$staged/${count * 5}');
          }
        }
      }
      if (batch.isNotEmpty) {
        await flush();
        batch.clear();
      }
      final token = await source.sealJob('scale-fixture', 'full-chain');
      await source.registerConfirmation('scale-confirmation', token);
      await CommitCoordinator(
        database: source,
        writeLock: lock,
        readActiveVersion: source.currentVersion,
        pageSize: 200,
      ).commitStaged(
        jobId: 'scale-fixture',
        expectedPreviewToken: token,
        confirmationEventId: 'scale-confirmation',
      );
    });
    final before = await measure('source_digest', () => digestDatabase(source));
    if (before['revision_count'] != count * 5 ||
        before['quotation_count'] != count) {
      throw StateError('Formal fixture cardinality mismatch');
    }
    final backup = _FileArtifact(File('${out.path}/source.backup'));
    final summary = await measure(
      'backup',
      () => BackupService(
        database: source,
        writeLock: lock,
        readActiveVersion: source.currentVersion,
        createArtifact: resources.artifact,
      ).create(backup.output),
    );
    final restored = resources.database('restored', restoredId);
    await measure(
      'restore_candidate',
      () => BackupCandidateBuilder(
        database: restored,
        writeLock: TestWriteLock(),
      ).build(backup.source),
    );
    final after = await measure(
      'restored_digest',
      () => digestDatabase(restored),
    );
    if (jsonEncode(before) != jsonEncode(after)) {
      throw StateError('Restored authority or business digest differs');
    }
    final version = await restored.currentVersion();
    final target = _FileArtifact(File('${out.path}/export.bundle.zip'));
    final budget = BundleBudget(
      compressedBytes: compressedBudget,
      expandedBytes: 3 * 1024 * 1024 * 1024,
      revisions: count * 5,
      volumes: ((count * 6) ~/ rowsPerVolume) + 100,
    );
    final manifest = await measure(
      'bundle_export_and_self_verify',
      () => exportBundle(
        snapshot: DatabaseBundleSnapshot(
          database: restored,
          version: version,
          columns: BundleColumns.schema2(),
        ),
        columns: BundleColumns.schema2(),
        budget: budget,
        bundleId: '90000000-0000-4000-8000-000000000001',
        exportedAt: authored,
        exporterVersion: 'full-chain-scale-v1',
        createArtifact: resources.artifact,
        createXlsxStaging: resources.xlsx,
        createBundleStaging: (version) async => DatabaseBundleStaging(
          database: resources.database(
            'verifier',
            '90000000-0000-4000-8000-000000000002',
          ),
          boundVersion: version,
        ),
        target: target.output,
        rowsPerVolume: rowsPerVolume,
      ),
    );
    if (manifest.revisionCount != count * 5 ||
        manifest.entityCounts['quotations'] != count ||
        manifest.revisionsDigest != before['bundle_revisions_sha256'] ||
        manifest.businessDigest != before['business_sha256']) {
      throw StateError('Export cardinality differs');
    }
    await File('${out.path}/manifest.json').writeAsString(manifest.encode());
    await resources.closeDatabase(restored);
    final reopened = resources.database('restored', restoredId);
    final reopenedDigest = await measure(
      'reopen_digest',
      () => digestDatabase(reopened),
    );
    if (jsonEncode(before) != jsonEncode(reopenedDigest)) {
      throw StateError('Reopened content differs');
    }
    return {
      'quotation_count': count,
      'revision_count': count * 5,
      'fixture_entry':
          'appendStaging -> sealJob -> registerConfirmation -> CommitCoordinator.commitStaged',
      'fixture_max_batch': 200,
      'scan_page_limit': 200,
      'snapshot_source':
          'one BackupService file, validated BackupCandidateBuilder restore; exporter reads only isolated restored DB',
      'source_version': versionJson(summary.header.version),
      'snapshot_version': versionJson(version),
      'source_digest': before,
      'restored_digest': after,
      'reopen_digest': reopenedDigest,
      'volume_count': manifest.volumes.length,
      'bundle_revision_digest': manifest.revisionsDigest,
      'bundle_business_digest': manifest.businessDigest,
      'backup_bytes': await backup.source.length(),
      'bundle_bytes': await target.source.length(),
      'timings_ms': timings,
      'phase_high_water_rss_bytes': stageRss,
      'phase_directory_bytes': stageSizes,
      'phase_space_checks': spaceChecks,
      'performance_acceptance':
          'measurements only; full-chain time/RSS gates must be evaluated separately',
    };
  } finally {
    await resources.close();
  }
}

Map<String, Object?> versionJson(DatabaseVersion version) => {
  'instance_id': version.instanceId,
  'active_epoch': version.activeEpoch,
  'generation': version.generation,
};

/// Domain and schema2 projection digests use bounded keyset reads. Receipt
/// integrity is additionally checked by the production backup candidate builder.
Future<Map<String, Object?>> digestDatabase(SupplierDatabase database) async {
  final digest = RollingDigest();
  final scan = await database.openScan();
  var count = 0;
  String? cursor;
  try {
    do {
      final page = await scan.readPage(after: cursor, limit: 200);
      for (final revision in page.items) {
        digest.add('${revision.revisionId}\t${revision.canonical}\n');
        count++;
      }
      cursor = page.nextCursor;
    } while (cursor != null);
  } finally {
    await scan.close();
  }
  final columns = BundleColumns.schema2();
  final snapshot = DatabaseBundleSnapshot(
    database: database,
    version: await database.currentVersion(),
    columns: columns,
  );
  final projections = BundleDigests(columns);
  for (final kind in bundleKinds) {
    projections.beginKind(kind);
    cursor = null;
    while (true) {
      var n = 0;
      await for (final row in snapshot.page(
        kind,
        afterKey: cursor,
        limit: 200,
      )) {
        projections.add(row);
        cursor = row.key;
        n++;
      }
      if (n < 200) break;
    }
  }
  final hashes = projections.finish();
  return {
    'revision_count': count,
    'quotation_count': projections.counts['quotations'],
    'authority_sha256': digest.finish(),
    'bundle_revisions_sha256': hashes.revisions,
    'business_sha256': hashes.business,
  };
}

class _Resources {
  _Resources(this.directory);
  final Directory directory;
  final databases = <SupplierDatabase>[];
  int sequence = 0;
  File? previousXlsx;
  int reserveBytes = 0;
  SupplierDatabase database(String name, String id) {
    final db = SupplierDatabase(
      NativeDatabase(File('${directory.path}/$name.sqlite')),
      instanceId: id,
    );
    databases.add(db);
    return db;
  }

  Future<void> closeDatabase(SupplierDatabase db) async {
    await db.close();
    databases.remove(db);
  }

  Future<BackupArtifact> artifact() async =>
      _FileArtifact(File('${directory.path}/private-${sequence++}.bin'));
  Future<XlsxStaging> xlsx() async {
    // The exporter closes validation before asking for its next volume.
    final previous = previousXlsx;
    if (previous != null && await previous.exists()) await previous.delete();
    if (await availableSpace(directory) < reserveBytes + 256 * 1024 * 1024) {
      throw const DomainFailure(
        'FULL_CHAIN_SPACE_BLOCKED',
        'Volume workspace would consume reserved capacity',
      );
    }
    final file = File('${directory.path}/xlsx-${sequence++}.sqlite');
    previousXlsx = file;
    return XlsxStaging(NativeDatabase(file));
  }

  Future<void> close() async {
    for (final db in databases.reversed) {
      await db.close();
    }
    databases.clear();
    final previous = previousXlsx;
    if (previous != null && await previous.exists()) await previous.delete();
    // This database belongs exclusively to exportBundle's completed verifier.
    // Retain source/restored/backup/bundle for independent evidence checks.
    final verifier = File('${directory.path}/verifier.sqlite');
    if (await verifier.exists()) await verifier.delete();
  }
}

class _FileArtifact implements BackupArtifact, InputSource, OutputTarget {
  _FileArtifact(this.file);
  final File file;
  bool ready = false;
  File get temporary => File('${file.path}.pending');
  @override
  InputSource get source => this;
  @override
  OutputTarget get output => this;
  @override
  String get displayName => file.path;
  @override
  Future<int> length() => file.length();
  @override
  Stream<List<int>> openRange(int start, int endExclusive) =>
      file.openRead(start, endExclusive);
  @override
  Future<void> write(Stream<List<int>> bytes) async {
    await temporary.create(exclusive: true);
    final handle = await temporary.open(mode: FileMode.writeOnly);
    try {
      await for (final chunk in bytes) {
        await handle.writeFrom(chunk);
      }
      await handle.flush();
      ready = true;
    } finally {
      await handle.close();
    }
  }

  @override
  Future<void> publish() async {
    if (!ready || await file.exists()) {
      throw StateError('Output not publishable');
    }
    await temporary.rename(file.path);
    ready = false;
  }

  @override
  Future<void> abort() async {
    if (await temporary.exists()) await temporary.delete();
  }

  @override
  Future<void> dispose() async {
    await abort();
    if (await file.exists()) await file.delete();
  }
}
