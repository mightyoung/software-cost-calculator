import 'dart:convert';
import 'package:drift/drift.dart';
import '../contracts.dart';
import '../data/database.dart';
import '../data/graph_workspace.dart';
import '../domain/canonical.dart';
import '../domain/entities.dart';
import '../domain/quotation.dart';
import '../domain/revision.dart';
import '../domain/revision_graph.dart';
import 'bundle_export.dart';
import 'bundle_import.dart';
import 'bundle_manifest.dart';
import 'projection_digest.dart';

const _types = {
  'suppliers': 'supplier',
  'contacts': 'contact',
  'products': 'product',
  'quotations': 'quotation',
};
const _metadata = [
  'entity_id',
  'entity_type',
  'revision_id',
  'relation_status',
  'payload',
  'canonical_supplier_id',
  'canonical_product_id',
  'canonical_contact_id',
];

void _columns(BundleColumns columns) {
  for (final kind in _types.keys) {
    final payloadFields = switch (kind) {
      'suppliers' => Supplier.fields,
      'contacts' => Contact.fields,
      'products' => Product.fields,
      _ => Quotation.fields,
    };
    final supported = {..._metadata, ...payloadFields};
    for (final field in columns.byKind[kind]!) {
      if (!supported.contains(field)) {
        throw ArgumentError('Unsupported frozen column $kind.$field');
      }
    }
  }
}

BundleRow _project(
  String id,
  String type,
  String? revision,
  String status,
  Map<String, Object?>? payload,
  List<String> columns,
  Map<String, Object?> canonicalReferences,
) {
  final fields = <String, Object?>{
    ...?payload,
    'entity_id': id,
    'entity_type': type,
    'revision_id': revision,
    'relation_status': status,
    'payload': payload == null ? null : canonicalJson(payload),
    ...canonicalReferences,
  };
  String? scalar(Object? value) => value == null
      ? null
      : value is String
      ? value
      : canonicalJson(value);
  return BundleRow(id, [for (final field in columns) scalar(fields[field])]);
}

/// The caller owns and freezes this database before constructing the adapter.
/// This class has no active-database resolver and never substitutes a later
/// generation. Checks bracket every bounded page, including after last yield.
final class DatabaseBundleSnapshot implements BundleSnapshot {
  DatabaseBundleSnapshot({
    required this.database,
    required this.version,
    required this.columns,
  }) {
    _columns(columns);
  }
  final SupplierDatabase database;
  @override
  final DatabaseVersion version;
  final BundleColumns columns;
  @override
  Future<void> assertFrozen() async {
    if (!sameVersion(version, await database.currentVersion())) {
      throw const DomainFailure(
        'SNAPSHOT_CHANGED',
        'Frozen bundle database version changed',
      );
    }
  }

  @override
  Stream<BundleRow> page(
    String kind, {
    String? afterKey,
    required int limit,
  }) async* {
    if (limit < 1 || limit > 5000 || !bundleKinds.contains(kind)) {
      throw ArgumentError('Invalid snapshot page');
    }
    await assertFrozen();
    // SQL may return up to 5000 requested rows, but fetch memory is capped at
    // 32 envelopes at once even when one history occupies the entire bundle.
    var remaining = limit, cursor = afterKey ?? '';
    while (remaining > 0) {
      final count = remaining.clamp(1, 32);
      await assertFrozen();
      if (kind == 'revisions') {
        final rows = await database.rows(
          'SELECT revision_id,entity_type,entity_id,canonical FROM revision WHERE revision_id>? ORDER BY revision_id LIMIT ?',
          [Variable(cursor), Variable(count)],
        );
        await assertFrozen();
        if (rows.isEmpty) break;
        for (final row in rows) {
          final id = row.read<String>('revision_id');
          yield BundleRow(id, [
            id,
            row.read<String>('entity_type'),
            row.read<String>('entity_id'),
            row.read<String>('canonical'),
          ]);
        }
        cursor = rows.last.read<String>('revision_id');
        remaining -= rows.length;
      } else {
        final type = _types[kind]!;
        final rows = await database.rows(
          'SELECT entity_id,revision_id,relation_status,payload,canonical_supplier_id,canonical_product_id,canonical_contact_id FROM ${type}_projection WHERE entity_id>? ORDER BY entity_id LIMIT ?',
          [Variable(cursor), Variable(count)],
        );
        await assertFrozen();
        if (rows.isEmpty) break;
        for (final row in rows) {
          final payload = row.readNullable<String>('payload');
          yield _project(
            row.read<String>('entity_id'),
            type,
            row.readNullable<String>('revision_id'),
            row.read<String>('relation_status'),
            payload == null
                ? null
                : jsonDecode(payload) as Map<String, Object?>,
            columns.byKind[kind]!,
            {
              for (final key in [
                'canonical_supplier_id',
                'canonical_product_id',
                'canonical_contact_id',
              ])
                key: row.data[key],
            },
          );
        }
        cursor = rows.last.read<String>('entity_id');
        remaining -= rows.length;
      }
    }
    await assertFrozen();
  }
}

/// Exclusive private SupplierDatabase, never the active business database.
/// The existing indexed graph validator runs against EMPTY local authority plus
/// the incoming revision set. It therefore proves closure of the package itself
/// before the application's later local-union validation/commit. No confirmation
/// event is registered and no business authority/projection is installed here.
final class DatabaseBundleStaging implements BundleStaging {
  DatabaseBundleStaging({required this.database, required this.boundVersion});
  final SupplierDatabase database;
  @override
  final DatabaseVersion boundVersion;

  /// Read-only transfer port for a later active-database staging attempt. The
  /// private seal is not a commit token; callers still validate the local union.
  Future<ScanPage<RevisionEnvelope>> revisionsPage({
    String? after,
    int limit = 32,
    required String sourceDigest,
  }) async {
    final state = await _state('sealed');
    if (state.read<String>('source_digest') != sourceDigest) {
      bundleFailure('Bundle source seal differs');
    }
    if (limit < 1 || limit > 200) throw ArgumentError.value(limit);
    return database.stagingPage(_job, after: after, limit: limit);
  }

  static const _job = 'bundle-incoming', _run = 'bundle-incoming-graph';
  String get _binding => canonicalJson({
    'instance': boundVersion.instanceId,
    'epoch': boundVersion.activeEpoch,
    'generation': boundVersion.generation,
  });
  Future<QueryRow> _state(String expected) async {
    final row = (await database.rows(
      'SELECT * FROM bundle_state WHERE singleton=1',
    )).single;
    if (row.read<String>('state') != expected ||
        row.read<String>('binding') != _binding) {
      throw const DomainFailure(
        'BUNDLE_STAGING_STATE',
        'Bundle staging is stale, failed or not in the requested phase',
      );
    }
    return row;
  }

  @override
  Future<void> begin(BundleManifest manifest) => database.transaction(() async {
    final version = await database.currentVersion();
    if (version.generation != 0 ||
        version.activeEpoch != 0 ||
        (await database.rows('SELECT 1 FROM revision LIMIT 1')).isNotEmpty ||
        (await database.rows('SELECT 1 FROM import_job LIMIT 1')).isNotEmpty) {
      throw const DomainFailure(
        'BUNDLE_STAGING_NOT_EMPTY',
        'Bundle staging requires an exclusively owned empty database',
      );
    }
    await database.customStatement(
      'CREATE TABLE bundle_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),state TEXT NOT NULL,binding TEXT NOT NULL,manifest TEXT NOT NULL,columns_json TEXT,verified_digest TEXT,source_digest TEXT)',
    );
    await database.customStatement(
      'CREATE TABLE bundle_row(kind TEXT NOT NULL,identity TEXT NOT NULL,cells TEXT NOT NULL,path TEXT NOT NULL,row_number INTEGER NOT NULL,PRIMARY KEY(kind,identity))',
    );
    for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
      await database.customStatement(
        "CREATE TRIGGER bundle_row_${operation.toLowerCase()} BEFORE $operation ON bundle_row WHEN (SELECT state FROM bundle_state WHERE singleton=1)='sealed' BEGIN SELECT RAISE(ABORT,'bundle staging is sealed'); END",
      );
    }
    await database.customStatement(
      "INSERT INTO bundle_state VALUES(1,'parsing',?,?,NULL,NULL,NULL)",
      [_binding, manifest.encode()],
    );
    await database.createJob(_job);
  });
  @override
  Future<void> append(
    String kind,
    BundleRow row, {
    required String path,
    required int rowNumber,
  }) async {
    try {
      await database.transaction(() async {
        await _state('parsing');
        if (!bundleKinds.contains(kind) ||
            row.cells.firstOrNull != row.key ||
            row.cells.length > 128 ||
            row.cells.any((c) => c != null && c.length > 32767) ||
            rowNumber < 2 ||
            path.length > 128) {
          bundleFailure('Invalid staged bundle row');
        }
        if ((await database.rows(
          'SELECT 1 FROM bundle_row WHERE kind=? AND identity=?',
          [Variable(kind), Variable(row.key)],
        )).isNotEmpty) {
          bundleFailure('Duplicate bundle identity');
        }
        await database.customStatement(
          'INSERT INTO bundle_row VALUES(?,?,?,?,?)',
          [kind, row.key, canonicalJson(row.cells), path, rowNumber],
        );
        if (kind == 'revisions') {
          if (row.cells.length != 4 || row.cells.any((c) => c == null)) {
            bundleFailure('Invalid revision technical cells');
          }
          final revision = RevisionEnvelope.fromCanonicalJson(row.cells[3]!);
          if (revision.revisionId != row.key ||
              revision.entityId != row.cells[2] ||
              revision.entityType != row.cells[1]) {
            bundleFailure('Revision identity mismatch');
          }
          await database.appendStaging(_job, revision);
        }
      });
    } catch (error, stack) {
      await discard();
      throw DomainFailure(
        'BUNDLE_ROW_INVALID',
        'Invalid bundle row at $path:$rowNumber',
        field: '$path:$rowNumber',
        cause: (error: error, stack: stack),
      );
    }
  }

  Future<({String revisions, String business})> _digest(
    BundleColumns columns,
  ) async {
    final result = BundleDigests(columns);
    for (final kind in bundleKinds) {
      result.beginKind(kind);
      var cursor = '';
      while (true) {
        final rows = await database.rows(
          'SELECT identity,cells FROM bundle_row WHERE kind=? AND identity>? ORDER BY identity LIMIT 32',
          [Variable(kind), Variable(cursor)],
        );
        if (rows.isEmpty) break;
        for (final row in rows) {
          result.add(
            BundleRow(
              row.read<String>('identity'),
              (jsonDecode(row.read<String>('cells')) as List).cast<String?>(),
            ),
          );
        }
        cursor = rows.last.read<String>('identity');
      }
    }
    return result.finish();
  }

  @override
  Future<void> verifyClosureAndProjection(
    BundleManifest manifest,
    BundleColumns columns,
  ) async {
    try {
      _columns(columns);
      final state = await _state('parsing');
      if ((await database.rows('SELECT 1 FROM revision LIMIT 1')).isNotEmpty) {
        bundleFailure('Private staging acquired business authority');
      }
      if (state.read<String>('manifest') != manifest.encode()) {
        bundleFailure('Manifest changed after parsing began');
      }
      await database.customStatement(
        "UPDATE bundle_state SET state='verifying',columns_json=?",
        [canonicalJson(columns.byKind)],
      );
      final actual = await _digest(columns);
      if (actual.revisions != manifest.revisionsDigest ||
          actual.business != manifest.businessDigest) {
        bundleFailure('Staged digest differs from manifest');
      }
      await database.sealJob(_job, manifest.businessDigest);
      final work = SqlGraphWorkspace(database, jobId: _job, runId: _run);
      await RevisionGraphValidator(pageSize: 32).validate(work);
      for (final kind in _types.keys) {
        final type = _types[kind]!;
        var cursor = '', count = 0;
        while (true) {
          final entities = await database.rows(
            'SELECT entity_id FROM graph_entity WHERE run_id=? AND entity_type=? AND entity_id>? ORDER BY entity_id LIMIT 32',
            [Variable(_run), Variable(type), Variable(cursor)],
          );
          if (entities.isEmpty) break;
          for (final row in entities) {
            final id = row.read<String>('entity_id'),
                entity = GraphEntity(type, row.read<String>('entity_id'));
            final relation = (await work.relation(entity))!,
                head = (await work.headSummary(entity)).single;
            final payload = head?.envelope.kind == 'put'
                ? head!.envelope.payload
                : null;
            final canonical = <String, Object?>{};
            for (final target in ['supplier', 'product', 'contact']) {
              final ref = payload?['${target}_id'] as String?;
              canonical['canonical_${target}_id'] = ref == null
                  ? null
                  : (await work.relation(
                      GraphEntity(target, ref),
                    ))?.canonical?.id;
            }
            final expected = _project(
              id,
              type,
              head?.id,
              relation.status.name,
              payload,
              columns.byKind[kind]!,
              canonical,
            );
            final incoming = await database.rows(
              'SELECT cells,path,row_number FROM bundle_row WHERE kind=? AND identity=?',
              [Variable(kind), Variable(id)],
            );
            if (incoming.isEmpty ||
                incoming.single.read<String>('cells') !=
                    canonicalJson(expected.cells)) {
              throw DomainFailure(
                'BUNDLE_PROJECTION_MISMATCH',
                'Projection differs for $kind/$id',
                field: incoming.isEmpty
                    ? '$kind/$id'
                    : '${incoming.single.read<String>('path')}:${incoming.single.read<int>('row_number')}',
              );
            }
            count++;
          }
          cursor = entities.last.read<String>('entity_id');
        }
        final staged = (await database.rows(
          'SELECT COUNT(*) n FROM bundle_row WHERE kind=?',
          [Variable(kind)],
        )).single.read<int>('n');
        if (count != staged || count != manifest.entityCounts[kind]) {
          bundleFailure('Projection identity set differs for $kind');
        }
      }
      final revisions = (await database.rows(
        'SELECT COUNT(*) n FROM staging_revision WHERE job_id=?',
        [Variable(_job)],
      )).single.read<int>('n');
      if (revisions != manifest.revisionCount) {
        bundleFailure('Revision count differs');
      }
      await database.customStatement(
        "UPDATE bundle_state SET state='verified',verified_digest=?",
        ['${actual.revisions}:${actual.business}'],
      );
    } catch (error, stack) {
      await discard();
      Error.throwWithStackTrace(error, stack);
    }
  }

  @override
  Future<void> seal(String sourceDigest) => database.transaction(() async {
    bundleHash(sourceDigest);
    final state = await _state('verified');
    if ((await database.rows('SELECT 1 FROM revision LIMIT 1')).isNotEmpty) {
      bundleFailure('Private staging acquired business authority');
    }
    final raw =
        (jsonDecode(state.read<String>('columns_json'))
            as Map<String, dynamic>);
    final columns = BundleColumns({
      for (final kind in _types.keys) kind: (raw[kind] as List).cast<String>(),
    });
    final digest = await _digest(columns);
    if ('${digest.revisions}:${digest.business}' !=
        state.read<String>('verified_digest')) {
      bundleFailure('Staging changed after validation');
    }
    // Bind the actual graph source too, not merely the separately retained XLSX
    // rows. No later local-union adapter may trust this private seal as a token.
    final mismatch = await database.rows(
      "SELECT 1 FROM staging_revision s LEFT JOIN bundle_row b ON b.kind='revisions' AND b.identity=s.revision_id WHERE s.job_id=? AND (b.identity IS NULL OR s.canonical<>json_extract(b.cells,'\$[3]')) LIMIT 1",
      [Variable(_job)],
    );
    final count = (await database.rows(
      'SELECT COUNT(*) n FROM staging_revision WHERE job_id=?',
      [Variable(_job)],
    )).single.read<int>('n');
    final rows = (await database.rows(
      "SELECT COUNT(*) n FROM bundle_row WHERE kind='revisions'",
    )).single.read<int>('n');
    if (mismatch.isNotEmpty || count != rows) {
      bundleFailure('Graph staging changed after validation');
    }
    await database.customStatement(
      "UPDATE bundle_state SET state='sealed',source_digest=?",
      [sourceDigest],
    );
  });
  @override
  Future<void> discard() async {
    if ((await database.rows(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name='bundle_state'",
    )).isEmpty) {
      return;
    }
    await database.customStatement(
      "UPDATE bundle_state SET state='failed',source_digest=NULL",
    );
    await SqlGraphWorkspace(database, jobId: _job, runId: _run).discardWork();
    await database.transaction(() async {
      await database.customStatement('DELETE FROM bundle_row');
      await database.customStatement(
        "UPDATE import_job SET state='failed' WHERE job_id=?",
        [_job],
      );
      await database.cleanupStaging(_job);
    });
  }
}
