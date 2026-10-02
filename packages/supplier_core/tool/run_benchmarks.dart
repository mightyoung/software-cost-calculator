/// Reproducible host-only T11 measurements. Run from packages/supplier_core.
/// Query fixtures bypass writes and are explicitly NOT import/commit evidence.
library;

import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:supplier_core/supplier_core.dart';
import '../test/support/test_rig.dart';
import '../test/support/xlsx_fixtures.dart';
import '../tools/generate_benchmark.dart' as structural;

const benchmarkSeed = 641921;

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  for (final arg in args) {
    final split = arg.indexOf('=');
    if (!arg.startsWith('--') || split < 3) {
      throw ArgumentError('Expected --mode=query|deep|strings --out=NEW_DIR');
    }
    options[arg.substring(2, split)] = arg.substring(split + 1);
  }
  final mode = options['mode'] ?? 'deep';
  if (!['query', 'deep', 'strings'].contains(mode)) {
    throw ArgumentError('Unknown benchmark mode');
  }
  final stringPattern = options['string-pattern'] ?? 'compressible';
  if (!['compressible', 'high-entropy'].contains(stringPattern)) {
    throw ArgumentError('Unknown string pattern');
  }
  final out = Directory(options['out'] ?? 'benchmark-$mode');
  if (out.existsSync()) throw ArgumentError('Output directory must be new');
  await out.create(recursive: true);
  final start = DateTime.now().toUtc();
  final elapsed = Stopwatch()..start();
  final report = <String, Object?>{
    'schema': 1,
    'mode': mode,
    'seed': benchmarkSeed,
    'command': [
      Platform.resolvedExecutable,
      Platform.script.toFilePath(),
      ...args,
    ],
    'started_at': start.toIso8601String(),
    'environment': {
      'os': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'dart': Platform.version,
      'processors': Platform.numberOfProcessors,
      'git_head': (await Process.run('git', [
        'rev-parse',
        'HEAD',
      ])).stdout.toString().trim(),
      'source_sha256': await sourceHashes(),
    },
    'scope': 'macOS/native host only; no Android/Windows/Web acceptance',
    'unverified': [
      'real disk full / browser quota exhaustion',
      'Windows and Android deferred by user',
      'Web page plus worker plus WASM total memory',
      'full import/export/backup/restore at target scale',
      'concurrent multi-volume export snapshot at target scale',
    ],
  };
  try {
    final budget = await checkSpace(
      out,
      mode: mode,
      count: int.parse(
        options['count'] ?? (mode == 'query' ? '10000' : '1000'),
      ),
      depth: int.parse(options['depth'] ?? '1000'),
      length: int.parse(options['length'] ?? '4000'),
    );
    report['space_budget'] = budget;
    if (budget['available_bytes']! < budget['required_bytes']!) {
      throw const DomainFailure(
        'BENCHMARK_SPACE_BLOCKED',
        'Requires estimated main database + equal journal + equal temporary workspace + 20% reserve',
      );
    }
    final result = switch (mode) {
      'query' => await runQuery(
        out,
        count: int.parse(options['count'] ?? '10000'),
      ),
      'deep' => await runDeep(
        out,
        depth: int.parse(options['depth'] ?? '1000'),
      ),
      _ => await runStrings(
        out,
        count: int.parse(options['count'] ?? '1000'),
        length: int.parse(options['length'] ?? '4000'),
        pattern: stringPattern,
      ),
    };
    report['result'] = result;
    report['status'] = 'PASS';
  } catch (error, stack) {
    report['status'] =
        error is DomainFailure && error.code == 'BENCHMARK_SPACE_BLOCKED'
        ? 'BLOCKED'
        : 'FAIL';
    report['error'] = error.toString();
    if (error is DomainFailure) report['failure_code'] = error.code;
    await File('${out.path}/failure.txt').writeAsString('$error\n$stack');
    exitCode = 1;
  } finally {
    report['elapsed_ms'] = elapsed.elapsedMilliseconds;
    report['process_peak_rss_bytes'] = ProcessInfo.maxRss;
    report['rss_scope'] =
        'whole Dart process including fixture construction, SQLite, native allocations; sampled OS process high-water mark via ProcessInfo.maxRss';
    report['source_sha256_at_finish'] = await sourceHashes();
    await File(
      '${out.path}/report.json',
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
    stdout.writeln('${report['status']}: ${out.path}/report.json');
  }
}

Future<Map<String, int>> checkSpace(
  Directory out, {
  required String mode,
  required int count,
  required int depth,
  required int length,
}) async {
  // Observed 10k query DB is 19645 bytes/quotation. Round UP to 24 KiB,
  // reserve another full main DB each for journal and temporary workspace,
  // then add 20%. This gate never treats a real disk-full test as passed.
  final estimated = switch (mode) {
    'query' => count * 24 * 1024,
    'deep' => depth * 8192,
    _ => count * length * 4,
  };
  final mainBytes = estimated < 64 * 1024 * 1024 ? 64 * 1024 * 1024 : estimated;
  final result = await Process.run('df', ['-Pk', out.absolute.path]);
  if (result.exitCode != 0) {
    throw const DomainFailure(
      'BENCHMARK_SPACE_BLOCKED',
      'Unable to measure free disk space',
    );
  }
  final fields = result.stdout
      .toString()
      .trim()
      .split('\n')
      .last
      .trim()
      .split(RegExp(r'\s+'));
  if (fields.length < 6 || int.tryParse(fields[3]) == null) {
    throw const DomainFailure(
      'BENCHMARK_SPACE_BLOCKED',
      'Unrecognized df space measurement',
    );
  }
  return {
    'estimated_main_bytes': mainBytes,
    'journal_reserve_bytes': mainBytes,
    'temporary_reserve_bytes': mainBytes,
    'required_bytes': (mainBytes * 3 * 1.2).ceil(),
    'available_bytes': int.parse(fields[3]) * 1024,
  };
}

Future<Map<String, Object?>> runQuery(
  Directory out, {
  required int count,
}) async {
  if (![10000, 100000].contains(count)) {
    throw ArgumentError('Query count must be 10000 or 100000');
  }
  final path = '${out.absolute.path}/query.sqlite';
  // In-process generation includes its native allocations in ProcessInfo.maxRss.
  await structural.main([
    '--count=$count',
    '--path=$path',
    '--report=${out.absolute.path}/generation.json',
  ]);
  final database = SupplierDatabase(
    NativeDatabase(File(path), enableMigrations: false),
    instanceId: 'query-fixture-$count',
  );
  try {
    final metadata = await environment(database);
    final scan = await database.openScan();
    final digest = RollingDigest();
    String? cursor, previous;
    var revisions = 0, maxPage = 0;
    final timer = Stopwatch()..start();
    try {
      do {
        final page = await scan.readPage(after: cursor, limit: 200);
        if (page.items.length > maxPage) maxPage = page.items.length;
        for (final revision in page.items) {
          if (previous != null &&
              previous.compareTo(revision.revisionId) >= 0) {
            throw StateError('Non-increasing revision cursor');
          }
          previous = revision.revisionId;
          digest.add('${revision.revisionId}\t${revision.canonical}\n');
          revisions++;
        }
        cursor = page.nextCursor;
      } while (cursor != null);
    } finally {
      await scan.close();
    }
    if (revisions != count * 5) {
      throw StateError('Revision cardinality differs');
    }
    final scanMs = timer.elapsedMilliseconds;
    final query = QueryRepository(
      database,
      calendarClock: () => DateTime(2026, 9, 17),
    );
    final quotationDigest = RollingDigest();
    var quotations = 0;
    cursor = null;
    timer.reset();
    do {
      final page = await query.quotations(
        {'sort': 'price_asc'},
        cursor: cursor,
        limit: 200,
      );
      for (final row in page.items) {
        quotationDigest.add('${row.id}\n');
        quotations++;
      }
      cursor = page.nextCursor;
    } while (cursor != null);
    if (quotations != count) throw StateError('Quotation cardinality differs');
    final paginationMs = timer.elapsedMilliseconds;
    final measurements = <String, Object?>{};
    for (final entry in <String, Map<String, Object?>>{
      'history': {},
      'price': {'sort': 'price_asc'},
      'prefix': {'product_name': 'product 1', 'text_mode': 'prefix'},
      'contains': {'product_name': 'duct 1', 'text_mode': 'contains'},
    }.entries) {
      for (var i = 0; i < 3; i++) {
        await query.quotations(entry.value);
      }
      final samples = <double>[];
      String? expected;
      for (var i = 0; i < 20; i++) {
        timer.reset();
        final page = await query.quotations(entry.value);
        samples.add(timer.elapsedMicroseconds / 1000);
        final actual = sha256
            .convert(utf8.encode(page.items.map((r) => r.id).join('\n')))
            .toString();
        expected ??= actual;
        if (actual != expected) throw StateError('Unstable warm query');
      }
      final sorted = [...samples]..sort();
      final target = entry.key == 'contains' ? 2000 : 500;
      measurements[entry.key] = {
        'warmups': 3,
        'samples_ms': samples,
        'p95_ms': sorted[18],
        'target_ms': target,
        'meets_target': sorted[18] <= target,
      };
    }
    return {
      ...metadata,
      'fixture_scope':
          'structural query fixture; synchronous OFF; NOT product write throughput or durability',
      'quotation_count': quotations,
      'revision_count': revisions,
      'revision_sha256': digest.finish(),
      'price_order_ids_sha256': quotationDigest.finish(),
      'scan_ms': scanMs,
      'pagination_ms': paginationMs,
      'max_scan_page': maxPage,
      'queries': measurements,
      'oracle':
          'Run verify_evidence.py for independent streaming SQLite comparison',
      'database_bytes': await File(path).length(),
    };
  } finally {
    await database.close();
  }
}

/// Real product commit, one growing history, O(1) fixture state plus 200 DB rows.
Future<Map<String, Object?>> runDeep(
  Directory out, {
  required int depth,
}) async {
  if (depth < 1 || depth > 500000) {
    throw ArgumentError('depth must be 1..500000');
  }
  final rig = StorageTestRig(File('${out.path}/deep.sqlite'));
  final timer = Stopwatch()..start();
  try {
    await rig.database.createJob('deep');
    String? previous;
    for (var start = 0; start < depth; start += 200) {
      await rig.database.transaction(() async {
        for (var i = start; i < depth && i < start + 200; i++) {
          final revision = RevisionEnvelope.create(
            entityType: 'supplier',
            entityId: fixtureRevision(1).entityId,
            parents: previous == null ? [] : [previous!],
            kind: 'put',
            payload: {...fixtureRevision(1).payload, 'name': 'Revision $i'},
            authoredAt: '2026-09-21T00:00:00.000Z',
            originDeviceId: fixtureRevision(1).originDeviceId,
          );
          await rig.database.appendStaging('deep', revision);
          previous = revision.revisionId;
        }
      });
    }
    final generationMs = timer.elapsedMilliseconds;
    final token = await rig.database.sealJob('deep', 'deep-chain');
    await rig.database.registerConfirmation('deep-event', token);
    timer.reset();
    await CommitCoordinator(
      database: rig.database,
      writeLock: rig.lock,
      readActiveVersion: rig.active,
      pageSize: 200,
    ).commitStaged(
      jobId: 'deep',
      expectedPreviewToken: token,
      confirmationEventId: 'deep-event',
    );
    final commitMs = timer.elapsedMilliseconds;
    final totals = await rig.database.rows('SELECT COUNT(*) n FROM revision');
    final heads = await rig.database.rows(
      'SELECT revision_id FROM entity_head',
    );
    if (totals.single.read<int>('n') != depth ||
        heads.length != 1 ||
        heads.single.read<String>('revision_id') != previous) {
      throw StateError(
        'Deep-chain count/head differs from O(1) fixture oracle',
      );
    }
    await rig.reopen();
    if (await rig.database.findRevision(previous!) == null) {
      throw StateError('Head missing after reopen');
    }
    return {
      ...await environment(rig.database),
      'depth': depth,
      'generation_ms': generationMs,
      'commit_ms': commitMs,
      'heads': 1,
      'head': previous,
      'reopen_verified': true,
      'oracle_retained_revisions': 1,
      'fixture_transaction_rows': 200,
    };
  } finally {
    await rig.database.close();
  }
}

String uniqueText(int index, int length, String pattern) {
  final prefix = index.toString().padLeft(8, '0');
  if (pattern == 'compressible') {
    return '$prefix${'x' * (length - prefix.length)}';
  }
  final text = StringBuffer(prefix);
  var block = 0;
  while (text.length < length) {
    final bytes = sha256.convert(utf8.encode('$index:$block')).bytes;
    text.write(base64Url.encode(bytes).replaceAll('=', ''));
    block++;
  }
  return text.toString().substring(0, length);
}

/// Adversarial volume fixture construction has a fixed 40 MiB ceiling. Its
/// allocations are INCLUDED in RSS; this is not a streaming-generator claim.
Future<Map<String, Object?>> runStrings(
  Directory out, {
  required int count,
  required int length,
  String pattern = 'compressible',
}) async {
  if (count < 1 ||
      count > 5000 ||
      length < 8 ||
      length > 32768 ||
      count * length > 40 * 1024 * 1024) {
    throw ArgumentError('Fixture exceeds bounded adversarial volume budget');
  }
  final source = xlsxFixture(
    shared:
        '<sst xmlns="$mainNs">${Iterable.generate(count, (i) => '<si><t>${uniqueText(i, length, pattern)}</t></si>').join()}</sst>',
    sheet: worksheet(
      '<row r="1"><c r="A1" t="inlineStr"><is><t>text</t></is></c></row>${Iterable.generate(count, (i) => '<row r="${i + 2}"><c r="A${i + 2}" t="s"><v>$i</v></c></row>').join()}',
    ),
  );
  final database = XlsxStaging(
    NativeDatabase(File('${out.path}/strings.sqlite')),
  );
  final timer = Stopwatch()..start();
  try {
    final profile = await const BoundedXlsxReader().readVolume(
      source,
      database,
    );
    final parseMs = timer.elapsedMilliseconds;
    for (var i = 0; i < count; i++) {
      final cells = await database.cellsPage(i + 2);
      if (cells.length != 1 ||
          cells.single.cell.lexical != uniqueText(i, length, pattern)) {
        throw StateError('Shared string $i differs from bounded oracle');
      }
    }
    if (profile.sharedStrings != count || profile.rows != count + 1) {
      throw StateError('XLSX count differs');
    }
    return {
      'count': count,
      'text_length': length,
      'string_pattern': pattern,
      'compressed_bytes': source.bytes.length,
      'parse_ms': parseMs,
      'profile': profile.toJson(),
      'oracle_retained_rows': 1,
    };
  } finally {
    await database.close();
  }
}

Future<Map<String, Object?>> environment(SupplierDatabase database) async => {
  'sqlite': (await database.rows(
    'SELECT sqlite_version() value',
  )).single.read<String>('value'),
  'journal_mode': (await database.rows(
    'PRAGMA journal_mode',
  )).single.read<String>('journal_mode'),
};

Future<Map<String, String>> sourceHashes() async {
  final hashes = <String, String>{};
  for (final path in [
    'pubspec.lock',
    'tool/run_benchmarks.dart',
    'tools/generate_benchmark.dart',
    'lib/src/query/query_repository.dart',
    'lib/src/data/commit_coordinator.dart',
    'lib/src/domain/revision_graph.dart',
    'lib/src/exchange/xlsx_reader.dart',
  ]) {
    hashes[path] = (await sha256.bind(File(path).openRead()).single).toString();
  }
  return hashes;
}

class RollingDigest {
  RollingDigest() {
    sink = sha256.startChunkedConversion(output);
  }
  final output = _DigestOutput();
  late final ByteConversionSink sink;
  void add(String text) => sink.add(utf8.encode(text));
  String finish() {
    sink.close();
    return output.value.toString();
  }
}

class _DigestOutput implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
