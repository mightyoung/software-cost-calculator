/// Resume evidence from an immutable, completed source database and backup.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
// SQLite is supplied by the pinned Drift native runtime; no dependency change.
// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:supplier_core/supplier_core.dart';
import '../test/support/test_rig.dart' show TestWriteLock;
import 'full_chain_scale.dart' as scale;

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  for (final arg in args) {
    final at = arg.indexOf('=');
    if (!arg.startsWith('--') || at < 3) {
      throw ArgumentError(
        'Use --input=DIR --out=NEW_DIR --count=N --authority=SHA256',
      );
    }
    options[arg.substring(2, at)] = arg.substring(at + 1);
  }
  if (options['prepare-backup'] == 'true') {
    final report = await prepareSourceBackup(
      Directory(options['input']!),
      count: int.parse(options['count']!),
      expectedAuthority: options['authority']!,
    );
    stdout.writeln(
      '${report['status']}: ${options['input']}/backup-preparation.json',
    );
    if (report['status'] != 'PASS') exitCode = 1;
    return;
  }
  final report = await resumeFullChain(
    Directory(options['input']!),
    Directory(options['out']!),
    count: int.parse(options['count']!),
    expectedAuthority: options['authority']!,
    rowsPerVolume: int.parse(options['rows-per-volume'] ?? '5000'),
  );
  stdout.writeln('${report['status']}: ${options['out']}/report.json');
  if (report['status'] != 'PASS') exitCode = 1;
}

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).single).toString();

/// Produce a real application backup for a previously completed import-only
/// fixture. The source remains available for the independent resumed chain.
Future<Map<String, Object?>> prepareSourceBackup(
  Directory input, {
  required int count,
  required String expectedAuthority,
}) async {
  if (count < 1 ||
      count > 100000 ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedAuthority)) {
    throw ArgumentError('Invalid count or authority');
  }
  final original = File('${input.absolute.path}/source.sqlite');
  final backup = File('${input.absolute.path}/source.backup');
  final evidence = File('${input.absolute.path}/backup-preparation.json');
  if (!await original.exists() ||
      await backup.exists() ||
      await evidence.exists()) {
    throw ArgumentError(
      'Completed source required; backup/evidence must be new',
    );
  }
  await _assertCheckpointHasNoSidecars(original);
  final report = <String, Object?>{
    'schema': 1,
    'kind': 'formal-backup-from-completed-source',
    'status': 'RUNNING',
    'count': count,
    'expected_authority_sha256': expectedAuthority,
    'source_path': original.path,
    'backup_path': backup.path,
    'started_at': DateTime.now().toUtc().toIso8601String(),
  };
  Future<void> save() => evidence.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  final sourceBefore = await _hash(original);
  final db = SupplierDatabase(
    NativeDatabase(File(original.path)),
    instanceId: scale.sourceId,
  );
  final watch = Stopwatch()..start();
  try {
    await save();
    final digest = await scale.digestDatabase(db);
    if (digest['authority_sha256'] != expectedAuthority ||
        digest['revision_count'] != count * 5 ||
        digest['quotation_count'] != count) {
      throw StateError('Source checkpoint digest or cardinality mismatch');
    }
    final artifact = _Artifact(backup);
    final summary = await BackupService(
      database: db,
      writeLock: TestWriteLock(),
      readActiveVersion: db.currentVersion,
      createArtifact: () async => _Artifact(
        File('${input.absolute.path}/private-backup-checkpoint.bin'),
      ),
    ).create(artifact);
    report['backup_digest'] = summary.digest;
    report['backup_bytes'] = summary.bytes;
    report['backup_counts'] = summary.header.counts;
    report['source_digest'] = digest;
  } catch (error, stack) {
    report['status'] = 'FAIL';
    report['error'] = '$error';
    report['stack'] = '$stack';
  } finally {
    await db.close();
    report['elapsed_ms'] = watch.elapsedMilliseconds;
    report['source_sha256_before'] = sourceBefore;
    report['source_sha256_after'] = await _hash(original);
    if (await backup.exists()) report['backup_sha256'] = await _hash(backup);
    report['finished_at'] = DateTime.now().toUtc().toIso8601String();
    if (report['status'] != 'FAIL') {
      report['status'] =
          report['source_sha256_after'] == sourceBefore && await backup.exists()
          ? 'PASS'
          : 'FAIL';
    }
    await save();
  }
  return report;
}

Future<Map<String, Object?>> resumeFullChain(
  Directory input,
  Directory out, {
  required int count,
  required String expectedAuthority,
  int rowsPerVolume = 5000,
  Future<int> Function(Directory) freeSpace = scale.availableSpace,
}) async {
  if (count < 1 ||
      count > 100000 ||
      rowsPerVolume < 1 ||
      rowsPerVolume > 5000 ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedAuthority)) {
    throw ArgumentError('Invalid expected count, digest or volume bound');
  }
  if (await out.exists()) throw ArgumentError('Output must be a new directory');
  final original = File('${input.absolute.path}/source.sqlite');
  final backup = _Input(File('${input.absolute.path}/source.backup'));
  if (!await original.exists() || !await backup.file.exists()) {
    throw ArgumentError('Source and published backup required');
  }
  await _assertCheckpointHasNoSidecars(original);
  await out.create(recursive: true);
  final watch = Stopwatch()..start();
  final timings = <String, int>{};
  final spaces = <String, Object?>{};
  final databases = <SupplierDatabase>[];
  var sequence = 0;
  var reserve = 0;
  File? previousXlsx;
  final report = <String, Object?>{
    'schema': 1,
    'kind': 'formal-full-chain-resumed',
    'status': 'RUNNING',
    'count': count,
    'expected_revisions': count * 5,
    'expected_authority_sha256': expectedAuthority,
    'resumed': true,
    'separate_process': true,
    'original_source_path': original.path,
    'original_backup_path': backup.file.path,
    'started_at': DateTime.now().toUtc().toIso8601String(),
    'missing_original_phase_timings': [
      'formal_fixture_commit',
      'source_digest',
      'backup',
    ],
    'performance_acceptance':
        'NOT_EVALUATED: interrupted original process; no aggregate time or RSS claim',
    'unverified': [
      'Android/Windows deferred by user',
      'restore active-pointer publication',
      'A17 concurrency/cancellation',
      'Web total memory',
    ],
  };
  Future<void> save() => File(
    '${out.path}/report.json',
  ).writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  Future<Map<String, String>> codeHashes() async => {
    ...await scale.sourceHashes(),
    'tool/resume_full_chain.dart': await _hash(
      File('tool/resume_full_chain.dart'),
    ),
  };
  final estimated = scale.estimatedMainBytes(count);
  final actual = await original.length();
  final bound = actual > estimated ? actual : estimated;
  final compressed = estimated.clamp(32 * 1024 * 1024, 1024 * 1024 * 1024);
  Future<T> phase<T>(
    String name,
    int working,
    Future<T> Function() action,
  ) async {
    final available = await freeSpace(out);
    reserve = (working * .2).ceil();
    spaces[name] = {
      'incremental_working_bytes': working,
      'required_free_bytes': working + reserve,
      'available_free_bytes': available,
    };
    report['phase_space_checks'] = spaces;
    report['current_phase'] = name;
    await save();
    if (available < working + reserve) {
      throw DomainFailure(
        'FULL_CHAIN_SPACE_BLOCKED',
        '$name requires ${working + reserve} bytes; available $available',
      );
    }
    stdout.writeln('phase=$name');
    final timer = Stopwatch()..start();
    final progress = Timer.periodic(
      const Duration(seconds: 30),
      (_) =>
          stdout.writeln('phase=$name elapsed_ms=${timer.elapsedMilliseconds}'),
    );
    try {
      return await action();
    } finally {
      progress.cancel();
      timings[name] = timer.elapsedMilliseconds;
    }
  }

  SupplierDatabase database(String name) {
    final db = SupplierDatabase(
      NativeDatabase(File('${out.path}/$name.sqlite')),
      instanceId: scale.restoredId,
    );
    databases.add(db);
    return db;
  }

  Future<BackupArtifact> artifact() async =>
      _Artifact(File('${out.path}/private-${sequence++}.bin'));
  try {
    report['source_sha256'] = await codeHashes();
    report['input_file_sha256'] = {
      'source': await _hash(original),
      'backup': await _hash(backup.file),
    };
    final source = SupplierDatabase(
      NativeDatabase.opened(
        sqlite.sqlite3.open(original.path, mode: sqlite.OpenMode.readOnly),
      ),
      instanceId: scale.sourceId,
    );
    databases.add(source);
    final before = await phase(
      'source_digest',
      32 * 1024 * 1024,
      () => scale.digestDatabase(source),
    );
    if (before['authority_sha256'] != expectedAuthority ||
        before['revision_count'] != count * 5 ||
        before['quotation_count'] != count) {
      throw StateError('Source checkpoint digest or cardinality mismatch');
    }
    final summary = await phase(
      'verify_backup',
      32 * 1024 * 1024,
      () => decodeBackup(backup),
    );
    final restored = database('restored');
    await phase(
      'restore_candidate',
      bound * 3,
      () => BackupCandidateBuilder(
        database: restored,
        writeLock: TestWriteLock(),
      ).build(backup),
    );
    final after = await phase(
      'restored_digest',
      32 * 1024 * 1024,
      () => scale.digestDatabase(restored),
    );
    if (jsonEncode(before) != jsonEncode(after)) {
      throw StateError('Restored digest differs from source');
    }
    final version = await restored.currentVersion();
    final target = _Artifact(File('${out.path}/export.bundle.zip'));
    final manifest = await phase(
      'bundle_export_and_self_verify',
      bound * 3 + compressed * 3 + 256 * 1024 * 1024,
      () => exportBundle(
        snapshot: DatabaseBundleSnapshot(
          database: restored,
          version: version,
          columns: BundleColumns.schema2(),
        ),
        columns: BundleColumns.schema2(),
        budget: BundleBudget(
          compressedBytes: compressed,
          expandedBytes: 3 * 1024 * 1024 * 1024,
          revisions: count * 5,
          volumes: ((count * 6) ~/ rowsPerVolume) + 100,
        ),
        bundleId: '90000000-0000-4000-8000-000000000001',
        exportedAt: scale.authored,
        exporterVersion: 'resume-full-chain-v1',
        createArtifact: artifact,
        createXlsxStaging: () async {
          if (previousXlsx != null && await previousXlsx!.exists()) {
            await previousXlsx!.delete();
          }
          if (await freeSpace(out) < reserve + 256 * 1024 * 1024) {
            throw const DomainFailure(
              'FULL_CHAIN_SPACE_BLOCKED',
              'Volume would consume reserve',
            );
          }
          final file = File('${out.path}/xlsx-${sequence++}.sqlite');
          previousXlsx = file;
          return XlsxStaging(NativeDatabase(file));
        },
        createBundleStaging: (boundVersion) async => DatabaseBundleStaging(
          database: database('verifier'),
          boundVersion: boundVersion,
        ),
        target: target,
        rowsPerVolume: rowsPerVolume,
      ),
    );
    if (manifest.revisionCount != count * 5 ||
        manifest.entityCounts['quotations'] != count ||
        manifest.revisionsDigest != before['bundle_revisions_sha256'] ||
        manifest.businessDigest != before['business_sha256']) {
      throw StateError('Bundle digest or cardinality mismatch');
    }
    await File('${out.path}/manifest.json').writeAsString(manifest.encode());
    await restored.close();
    databases.remove(restored);
    final reopened = await phase(
      'reopen_digest',
      32 * 1024 * 1024,
      () => scale.digestDatabase(database('restored')),
    );
    if (jsonEncode(before) != jsonEncode(reopened)) {
      throw StateError('Reopened digest differs');
    }
    report['result'] = {
      'source_digest': before,
      'restored_digest': after,
      'reopen_digest': reopened,
      'source_version': scale.versionJson(summary.header.version),
      'snapshot_version': scale.versionJson(version),
      'revision_count': count * 5,
      'quotation_count': count,
      'volume_count': manifest.volumes.length,
      'backup_bytes': await backup.length(),
      'bundle_bytes': await target.length(),
    };
    report['status'] = 'PASS';
  } catch (error, stack) {
    report['status'] =
        error is DomainFailure && error.code == 'FULL_CHAIN_SPACE_BLOCKED'
        ? 'BLOCKED'
        : 'FAIL';
    report['error'] = '$error';
    await File('${out.path}/failure.txt').writeAsString('$error\n$stack');
  } finally {
    try {
      for (final db in databases.reversed) {
        await db.close();
      }
      report['input_file_sha256_at_finish'] = {
        'source': await _hash(original),
        'backup': await _hash(backup.file),
      };
      await _assertCheckpointHasNoSidecars(original);
      report['source_sha256_at_finish'] = await codeHashes();
      if (jsonEncode(report['input_file_sha256']) !=
              jsonEncode(report['input_file_sha256_at_finish']) ||
          jsonEncode(report['source_sha256']) !=
              jsonEncode(report['source_sha256_at_finish'])) {
        report['status'] = 'FAIL';
        report['error'] =
            'Input files or implementation changed during resumed run';
      }
    } catch (error) {
      report['status'] = 'FAIL';
      report['finalization_error'] = '$error';
    }
    report['elapsed_ms'] = watch.elapsedMilliseconds;
    report['resumed_process_peak_rss_bytes'] = ProcessInfo.maxRss;
    report['resumed_timings_ms'] = timings;
    await save();
  }
  return report;
}

Future<void> _assertCheckpointHasNoSidecars(File source) async {
  // The main-file hash alone cannot detect a writer that created a new WAL.
  for (final suffix in ['-wal', '-journal', '-shm']) {
    if (await File('${source.path}$suffix').exists()) {
      throw StateError('Source has $suffix; checkpoint is not immutable');
    }
  }
}

class _Input implements InputSource {
  _Input(this.file);
  final File file;
  @override
  String get displayName => file.path;
  @override
  Future<int> length() => file.length();
  @override
  Stream<List<int>> openRange(int start, int endExclusive) =>
      file.openRead(start, endExclusive);
}

class _Artifact extends _Input implements BackupArtifact, OutputTarget {
  _Artifact(super.file);
  bool ready = false;
  File get pending => File('${file.path}.pending');
  @override
  InputSource get source => this;
  @override
  OutputTarget get output => this;
  @override
  Future<void> write(Stream<List<int>> bytes) async {
    await pending.create(exclusive: true);
    final handle = await pending.open(mode: FileMode.writeOnly);
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
    await pending.rename(file.path);
    ready = false;
  }

  @override
  Future<void> abort() async {
    if (await pending.exists()) await pending.delete();
  }

  @override
  Future<void> dispose() async {
    await abort();
    if (await file.exists()) await file.delete();
  }
}
