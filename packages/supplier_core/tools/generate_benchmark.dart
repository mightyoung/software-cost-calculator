/// QUERY-ONLY structural fixture. This tool deliberately bypasses product graph
/// validation, is never exported, and must never open a user's business file.
/// Produces deterministic protocol envelopes plus typed projections for query
/// plans/timings. It is not evidence for product write throughput or T11 p95.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:supplier_core/src/data/database.dart';
import 'package:supplier_core/src/domain/revision.dart';
import 'package:supplier_core/src/domain/quotation.dart';
import 'package:supplier_core/src/query/query_repository.dart';
import 'package:supplier_core/src/query/candidates.dart';
import 'package:supplier_core/src/query/search_keys.dart';

String fixtureId(int n) =>
    '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
Future<void> main(List<String> arguments) async {
  final options = {
    for (final arg in arguments)
      if (arg.startsWith('--') && arg.contains('='))
        arg.substring(2, arg.indexOf('=')): arg.substring(arg.indexOf('=') + 1),
  };
  if (options.containsKey('measure-existing')) {
    await _measureExisting(options);
    return;
  }
  final count = int.parse(options['count'] ?? '10000');
  if (![10000, 100000].contains(count)) {
    throw ArgumentError('count must be 10000 or 100000');
  }
  final path = options['path'];
  if (path == null || await File(path).exists()) {
    throw ArgumentError(
      'Pass a new --path; existing databases are never modified',
    );
  }
  final db = SupplierDatabase(
    NativeDatabase(File(path)),
    instanceId: 'query-fixture-$count',
  );
  final writer = _Writer(db);
  final random = Random(641921);
  final supplierCount = count ~/ 10,
      productCount = count ~/ 5,
      contactCount = count ~/ 5;
  final watch = Stopwatch()..start();
  var revisions = 0;
  try {
    // Disposable query-fixture generation only; no durability evidence.
    await db.customStatement('PRAGMA cache_size=-65536');
    await db.customStatement('PRAGMA synchronous=OFF');
    await db.transaction(() async {
      Future<void> entity(
        String type,
        int number,
        Map<String, Object?> payload, {
        int history = 1,
      }) async {
        final id = fixtureId(number);
        writer.add('entity_identity', {'entity_type': type, 'entity_id': id});
        RevisionEnvelope? previous;
        String? previousId;
        for (var v = 0; v < history; v++) {
          final row = RevisionEnvelope.create(
            entityType: type,
            entityId: id,
            parents: previousId == null ? [] : [previousId],
            kind: 'put',
            payload: {
              ...payload,
              if (v < history - 1) 'notes': 'Fixture historical revision $v',
            },
            authoredAt: '2026-09-17T00:00:00.000Z',
            originDeviceId: fixtureId(999999999),
          );
          final canonical = row.canonical;
          final revisionId = sha256.convert(utf8.encode(canonical)).toString();
          writer.add('revision', {
            'revision_id': revisionId,
            'entity_type': type,
            'entity_id': id,
            'canonical': canonical,
          });
          if (previous != null) {
            writer.add('revision_parent', {
              'child_id': revisionId,
              'parent_id': previousId,
            });
          }
          previous = row;
          previousId = revisionId;
          revisions++;
        }
        final row = previous!;
        final quote = type == 'quotation' ? Quotation.fromJson(payload) : null;
        writer.add('entity_head', {
          'entity_type': type,
          'entity_id': id,
          'revision_id': previousId,
        });
        writer.add('alias_projection', {
          'entity_type': type,
          'entity_id': id,
          'canonical_id': id,
          'relation_status': 'active',
        });
        final fields = <String, Object?>{
          'entity_id': id,
          'entity_type': type,
          'revision_id': previousId,
          'payload': jsonEncode(row.payload),
          'relation_status': 'active',
          'name': payload['name'],
          'supplier_id': payload['supplier_id'],
          'product_id': payload['product_id'],
          'canonical_supplier_id': payload['supplier_id'],
          'canonical_product_id': payload['product_id'],
          'canonical_contact_id': payload['contact_id'],
          'search_text': searchKey(jsonEncode(payload)),
          ...projectionSearchKeys(payload),
          'price_key': quote?.priceKey,
          'missing_context': quote == null
              ? null
              : jsonEncode(quote.missingContext),
          'missing_context_count': quote?.missingContext.length,
          for (final name in [
            'currency',
            'unit_snapshot',
            'tax_mode',
            'min_qty',
            'tax_rate',
            'project_name',
            'project_number',
            'inquiry_location',
            'inquirer_name',
            'inquiry_precision',
            'inquiry_date',
            'inquired_at',
            'quoted_on',
            'valid_until',
            'brand',
            'model',
            'contact_id',
            'capture_mode',
          ])
            name: payload[name],
        };
        writer.add('${type}_projection', fields);
        if (type == 'quotation') {
          writer.add('quotation_head_projection', fields);
        }
        for (final term in candidateTerms(type, payload)) {
          writer.add('candidate_term', {
            'entity_type': type,
            'entity_id': id,
            'field': term.$1,
            'search_key': term.$2,
            'original_text': term.$3,
          });
        }
        for (final field in ['supplier_id', 'product_id', 'contact_id']) {
          if (payload[field] != null) {
            writer.add('reference_projection', {
              'source_type': type,
              'source_id': id,
              'field': field,
              'target_type': field.substring(0, field.length - 3),
              'target_id': payload[field],
            });
          }
        }
      }

      for (var i = 0; i < supplierCount; i++) {
        await entity('supplier', 1 + i, {
          'name': 'Supplier ${i % 200} ${'S' * (i % 79 == 0 ? 160 : 8)}',
          'aliases': ['ＡＬＩＡＳ ${i % 100}'],
          'address': 'Address ${i % 50}',
          'categories': ['component'],
          'notes': null,
        });
        if (i % 200 == 199) await writer.flush();
      }
      await writer.flush();
      for (var i = 0; i < productCount; i++) {
        await entity('product', 100000 + i, {
          'name': 'Product ${i % 400}',
          'unit': '件',
          'brand': 'Brand ${i % 20}',
          'model': 'Ｍ-${i % 100}/A.%',
          'specification': 'Specification ${i % 200}',
          'category': 'parts',
          'notes': null,
        });
        if (i % 200 == 199) await writer.flush();
      }
      await writer.flush();
      for (var i = 0; i < contactCount; i++) {
        await entity('contact', 200000 + i, {
          'supplier_id': fixtureId(1 + i % supplierCount),
          'name': 'Person ${i % 500}',
          'phone': '${10000000000 + i}',
          'wechat': null,
          'email': null,
          'notes': null,
        });
        if (i % 200 == 199) await writer.flush();
      }
      await writer.flush();
      for (var i = 0; i < count; i++) {
        final missing = i % 31 == 0,
            quoted = i % 97 == 0
                ? '2026-09-18'
                : '2026-09-${(1 + i % 16).toString().padLeft(2, '0')}';
        final supplier = fixtureId(1 + i % supplierCount),
            product = fixtureId(100000 + i % productCount),
            contact = fixtureId(200000 + i % contactCount);
        final payload = <String, Object?>{
          'supplier_id': supplier,
          'product_id': product,
          'price':
              '${random.nextInt(10000)}.${random.nextInt(1000000).toString().padLeft(6, '0')}',
          'currency': i % 7 == 0 ? 'USD' : 'CNY',
          'tax_mode': i % 13 == 0
              ? 'unknown'
              : i % 3 == 0
              ? 'included'
              : 'excluded',
          'unit_snapshot': i % 23 == 0 ? '箱' : '件',
          'min_qty': i % 5 == 0 ? '10' : '1',
          'quoted_on': quoted,
          'contact_id': contact,
          'contact_snapshot': {
            'name': 'Person ${i % contactCount % 500}',
            'phone': '${10000000000 + i % contactCount}',
            'wechat': null,
            'email': null,
          },
          'tax_rate': i % 3 == 0 && i % 11 != 0 ? '13' : null,
          'lead_time_days': null,
          'valid_until': i % 7 == 0
              ? null
              : i % 19 == 0 && quoted.compareTo('2026-09-16') <= 0
              ? '2026-09-16'
              : '2026-10-30',
          'notes': i % 101 == 0 ? 'N' * 1800 : null,
          'project_name': missing ? null : 'Project ${i % 300}',
          'project_number': missing
              ? null
              : '${(i % 200).toString().padLeft(6, '0')}-Ａ',
          'inquiry_location': 'City ${i % 20}',
          'inquirer_name': missing ? null : 'Person ${i % 500}',
          'inquiry_precision': missing ? 'unknown' : 'date',
          'inquiry_date': missing
              ? null
              : '2026-09-${(1 + i % 16).toString().padLeft(2, '0')}',
          'inquired_at': null,
          'inquiry_utc_offset_minutes': null,
          'capture_mode': missing ? 'historical' : 'standard',
        };
        await entity('quotation', 1000000 + i, payload, history: 4 + i % 2);
        if (i % 200 == 199) await writer.flush();
        if (i % 10000 == 9999) {
          stderr.writeln(
            'Generated ${i + 1}/$count quotations; $revisions canonical revisions',
          );
        }
      }
      await writer.flush();
      await db.customStatement('UPDATE database_meta SET generation=1');
    });
    final generationMs = watch.elapsedMilliseconds;
    await db.customStatement('ANALYZE');
    final repository = QueryRepository(
      db,
      calendarClock: () => DateTime(2026, 9, 17),
    );
    final queries = <String, Map<String, Object?>>{
      'history': {},
      'quoted_history': {'sort': 'quoted_on_desc'},
      'price_history': {'sort': 'price_asc'},
      'product_history': {'product_id': fixtureId(100000)},
      'supplier_history': {'supplier_id': fixtureId(1)},
      'project_person': {
        'project_number': '000010-a',
        'inquirer_name': 'person 10',
      },
      'confirmed_lowest': {
        'view': 'confirmed_lowest',
        'product_id': fixtureId(100000),
        'as_of': '2026-09-17',
      },
      'product_name_prefix': {
        'product_name': 'product 1',
        'text_mode': 'prefix',
      },
      'product_name_contains': {
        'product_name': 'duct 1',
        'text_mode': 'contains',
      },
    };
    final results = <String, Object?>{};
    for (final entry in queries.entries) {
      watch.reset();
      final result = await repository.quotations(entry.value);
      results[entry.key] = {
        'first_query_ms': watch.elapsedMicroseconds / 1000,
        'rows': result.items.length,
        'plan': await repository.explain(entry.value),
      };
    }
    final candidates = CandidateRepository(db);
    final candidateResults = <String, Object?>{};
    for (final mode in SearchMode.values) {
      watch.reset();
      final result = await candidates.find('product', {
        'model': mode == SearchMode.contains
            ? '1/A'
            : mode == SearchMode.exact
            ? 'm-1/a.%'
            : 'm-1',
      }, mode: mode);
      candidateResults[mode.name] = {
        'first_query_ms': watch.elapsedMicroseconds / 1000,
        'rows': result.length,
        'plan': await candidates.explain(
          'product',
          'model',
          mode == SearchMode.contains
              ? '1/A'
              : mode == SearchMode.exact
              ? 'm-1/a.%'
              : 'm-1',
          mode: mode,
        ),
      };
    }
    final report = {
      'fixture':
          'query-only structural projections; no product-write/performance approval',
      'seed': 641921,
      'quotation_count': count,
      'supplier_count': supplierCount,
      'product_count': productCount,
      'contact_count': contactCount,
      'revision_count': revisions,
      'generation_ms': generationMs,
      'backend': 'SQLite native file query-only fixture',
      'sqlite_cache_kib': 65536,
      'fixture_write_synchronous':
          'OFF - disposable fixture only, not durability evidence',
      'file_bytes': await File(path).length(),
      'max_buffered_rows': writer.maxRows,
      'field_distribution': {
        'supplier_name_max': 173,
        'notes_max': 1800,
        'product_names': 400,
        'models': 100,
        'projects': 300,
        'missing_context_every': 31,
        'unknown_expiry_every': 7,
      },
      'search_key_version': searchKeyVersion,
      'queries': results,
      'candidates': candidateResults,
    };
    final json = const JsonEncoder.withIndent('  ').convert(report);
    if (options['report'] != null) {
      await File(options['report']!).writeAsString('$json\n');
    }
    print(json);
  } finally {
    await db.close();
  }
}

class _Writer {
  _Writer(this.db);
  final SupplierDatabase db;
  final _rows = <String, List<List<Object?>>>{};
  final _columns = <String, List<String>>{};
  int maxRows = 0;
  void add(String table, Map<String, Object?> values) {
    _columns.putIfAbsent(table, () => values.keys.toList());
    (_rows[table] ??= []).add(values.values.toList());
    maxRows = max(
      maxRows,
      _rows.values.fold(0, (sum, rows) => sum + rows.length),
    );
  }

  Future<void> flush() async {
    const order = [
      'entity_identity',
      'revision',
      'revision_parent',
      'entity_head',
      'alias_projection',
      'supplier_projection',
      'product_projection',
      'contact_projection',
      'quotation_projection',
      'quotation_head_projection',
      'candidate_term',
      'reference_projection',
    ];
    for (final table in order) {
      final rows = _rows[table];
      if (rows == null || rows.isEmpty) continue;
      final columns = _columns[table]!;
      final placeholders = '(${List.filled(columns.length, '?').join(',')})';
      // Bound SQLite variables and memory even for wide projections.
      for (var start = 0; start < rows.length; start += 200) {
        final page = rows.skip(start).take(200).toList();
        await db.customStatement(
          'INSERT INTO $table(${columns.join(',')}) VALUES ${List.filled(page.length, placeholders).join(',')}',
          [for (final row in page) ...row],
        );
      }
      rows.clear();
    }
  }
}

Future<void> _measureExisting(Map<String, String> options) async {
  final path = options['measure-existing']!;
  if (!await File(path).exists()) {
    throw ArgumentError('Existing fixture required');
  }
  final rounds = int.parse(options['rounds'] ?? '20');
  if (rounds < 1 || rounds > 100) throw ArgumentError('rounds must be 1..100');
  final db = SupplierDatabase(
    NativeDatabase(
      File(path),
      enableMigrations: false,
      setup: (connection) {
        connection.execute('PRAGMA cache_size=-65536');
      },
    ),
    instanceId: 'existing-query-fixture',
  );
  try {
    final identity = (await db.currentVersion()).instanceId;
    if (!['query-fixture-10000', 'query-fixture-100000'].contains(identity)) {
      throw ArgumentError('Only generated query fixtures may be measured');
    }
    final query = QueryRepository(
      db,
      calendarClock: () => DateTime(2026, 9, 17),
    );
    final measurements = <String, Object?>{};
    for (final mode in ['prefix', 'contains']) {
      final filters = <String, Object?>{
        'product_name': mode == 'prefix' ? 'product 1' : 'duct 1',
        'text_mode': mode,
        'as_of': '2026-09-17',
      };
      for (var warm = 0; warm < 3; warm++) {
        await query.quotations(filters);
      }
      final samples = <double>[];
      String? resultDigest;
      for (var round = 0; round < rounds; round++) {
        final timer = Stopwatch()..start();
        final page = await query.quotations(filters);
        samples.add(timer.elapsedMicroseconds / 1000);
        final digest = sha256
            .convert(
              utf8.encode(jsonEncode(page.items.map((row) => row.id).toList())),
            )
            .toString();
        if (resultDigest != null && resultDigest != digest) {
          throw StateError('Unstable query result');
        }
        resultDigest = digest;
      }
      final ordered = [...samples]..sort();
      final p95 = ordered[(rounds * .95).ceil() - 1];
      final target = mode == 'prefix' ? 500 : 2000;
      measurements[mode] = {
        'warmup_rounds': 3,
        'rounds': rounds,
        'samples_ms': samples,
        'p95_ms_nearest_rank': p95,
        'target_ms': target,
        'meets_target': p95 <= target,
        'result_ids_sha256': resultDigest,
        'plan': await query.explain(filters),
      };
    }
    final report = {
      'fixture': path,
      'operations':
          'SELECT/EXPLAIN only on disposable clone; Drift read snapshots use BEGIN IMMEDIATE',
      'sqlite_cache_kib': 65536,
      'as_of': '2026-09-17',
      'measurement':
          'warm native host query samples, not Android/Windows/Web platform approval',
      'queries': measurements,
    };
    final output = const JsonEncoder.withIndent('  ').convert(report);
    if (options['report'] != null) {
      await File(options['report']!).writeAsString('$output\n');
    }
    print(output);
  } finally {
    await db.close();
  }
}
