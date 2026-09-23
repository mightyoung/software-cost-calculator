import 'package:drift/drift.dart';
import '../contracts.dart';
import '../domain/revision.dart';
import '../domain/revision_graph.dart';
import 'database.dart';

/// Persistent indexed workspace, isolated by a non-reusable run identity.
/// It is diagnostic storage, never itself a commit authorization.
class SqlGraphWorkspace implements GraphWorkspace {
  SqlGraphWorkspace(this.database, {required this.jobId, required this.runId});
  final SupplierDatabase database;
  final String jobId, runId;
  Future<void> _usable() async {
    final rows = await database.rows(
      'SELECT state FROM graph_run WHERE run_id=?',
      [Variable(runId)],
    );
    if (rows.length != 1 || rows.single.read<String>('state') != 'running') {
      throw const DomainFailure(
        'graph_run_quarantined',
        'Graph run is absent, discarded or quarantined',
      );
    }
  }

  Future<List<QueryRow>> _read(
    String sql, [
    List<Object> args = const [],
  ]) async {
    await _usable();
    return database.rows(
      sql,
      args
          .map(
            (v) => v is int ? Variable<int>(v) : Variable<String>(v as String),
          )
          .toList(),
    );
  }

  Future<void> _write(String sql, [List<Object?> args = const []]) async {
    if (!sql.startsWith('INSERT INTO graph_run') &&
        !sql.startsWith('UPDATE graph_run')) {
      await _usable();
    }
    await database.customStatement(sql, args);
  }

  @override
  Future<GraphBinding> currentBinding() async {
    final job = await database.job(jobId);
    final digest = job.readNullable<String>('sealed_digest');
    if (digest == null) {
      throw const DomainFailure('unsealed_job', 'Graph input must be sealed');
    }
    return GraphBinding(
      database: await database.currentVersion(),
      jobId: jobId,
      sealedDigest: digest,
    );
  }

  @override
  Future<void> resetWork(GraphBinding binding) async {
    if (!binding.sameAs(await currentBinding())) {
      throw const DomainFailure('graph_stale_binding', 'Input changed');
    }
    await database.transaction(() async {
      await _write('INSERT INTO graph_run(run_id,job_id,state) VALUES(?,?,?)', [
        runId,
        jobId,
        'running',
      ]);
      final collision = await _read(
        'SELECT 1 FROM staging_revision s JOIN revision r ON r.revision_id=s.revision_id WHERE s.job_id=? AND s.canonical<>r.canonical LIMIT 1',
        [jobId],
      );
      if (collision.isNotEmpty) {
        throw const DomainFailure(
          'revision_collision',
          'Different canonical payloads share revision ID',
        );
      }
      await _write(
        'INSERT INTO graph_revision SELECT ?,revision_id,entity_type,entity_id,canonical FROM revision',
        [runId],
      );
      await _write(
        'INSERT INTO graph_revision SELECT ?,revision_id,json_extract(canonical,\'\$.entity_type\'),json_extract(canonical,\'\$.entity_id\'),canonical FROM staging_revision WHERE job_id=? ON CONFLICT(run_id,revision_id) DO NOTHING',
        [runId, jobId],
      );
      await _write(
        'INSERT INTO graph_entity SELECT DISTINCT run_id,entity_type,entity_id FROM graph_revision WHERE run_id=?',
        [runId],
      );
      await _write(
        'INSERT INTO graph_edge SELECT r.run_id,r.revision_id,p.value FROM graph_revision r,json_each(r.canonical,\'\$.parents\') p WHERE r.run_id=?',
        [runId],
      );
    });
  }

  @override
  Future<void> discardWork() async {
    // Persist quarantine BEFORE potentially failing cleanup, so restart cannot
    // expose retained partial results. Never reuse any old run identity.
    await _write(
      'INSERT INTO graph_run(run_id,job_id,state) VALUES(?,?,?) ON CONFLICT(run_id) DO UPDATE SET state=excluded.state',
      [runId, jobId, 'quarantined'],
    );
    await database.transaction(() async {
      for (final table in graphWorkTables) {
        await database.customStatement('DELETE FROM $table WHERE run_id=?', [
          runId,
        ]);
      }
      await _write('UPDATE graph_run SET state=? WHERE run_id=?', [
        'discarded',
        runId,
      ]);
    });
  }

  GraphRevision _revision(QueryRow row) {
    final envelope = RevisionEnvelope.fromCanonicalJson(
      row.read<String>('canonical'),
    );
    final id = row.read<String>('revision_id');
    if (envelope.revisionId != id ||
        envelope.entityType != row.read<String>('entity_type') ||
        envelope.entityId != row.read<String>('entity_id')) {
      throw const DomainFailure(
        'revision_hash_mismatch',
        'Authority identity differs from canonical envelope',
      );
    }
    return GraphRevision(id, envelope);
  }

  @override
  Future<ScanPage<GraphRevision>> readRevisions({
    String? after,
    required int limit,
  }) async {
    checkLimit(limit);
    final rows = await _read(
      'SELECT * FROM graph_revision WHERE run_id=? AND revision_id>? ORDER BY revision_id LIMIT ?',
      [runId, after ?? '', limit + 1],
    );
    final items = rows.take(limit).map(_revision).toList();
    return ScanPage(
      items,
      limit: limit,
      nextCursor: rows.length > limit ? items.last.id : null,
    );
  }

  @override
  Future<GraphRevision?> findRevision(String id) async {
    final rows = await _read(
      'SELECT * FROM graph_revision WHERE run_id=? AND revision_id=?',
      [runId, id],
    );
    return rows.isEmpty ? null : _revision(rows.single);
  }

  @override
  Future<bool> hasEntity(GraphEntity e) async => (await _read(
    'SELECT 1 FROM graph_entity WHERE run_id=? AND entity_type=? AND entity_id=?',
    [runId, e.type, e.id],
  )).isNotEmpty;
  @override
  Future<ScanPage<GraphEntity>> readEntities({
    String? after,
    required int limit,
  }) async {
    final cursor = entityCursor(after);
    return _entities(
      'SELECT entity_type,entity_id FROM graph_entity WHERE run_id=? AND (entity_type,entity_id)>(?,?) ORDER BY entity_type,entity_id LIMIT ?',
      [runId, cursor.$1, cursor.$2, limit + 1],
      limit,
    );
  }

  Future<ScanPage<GraphEntity>> readAffectedEntities({
    String? after,
    required int limit,
  }) async {
    final cursor = entityCursor(after);
    return _entities(
      'SELECT entity_type,entity_id FROM graph_affected WHERE run_id=? AND (entity_type,entity_id)>(?,?) ORDER BY entity_type,entity_id LIMIT ?',
      [runId, cursor.$1, cursor.$2, limit + 1],
      limit,
    );
  }

  Future<ScanPage<GraphEntity>> _entities(
    String sql,
    List<Object> args,
    int limit,
  ) async {
    checkLimit(limit);
    final rows = await _read(sql, args);
    final items = rows
        .take(limit)
        .map(
          (r) => GraphEntity(
            r.read<String>('entity_type'),
            r.read<String>('entity_id'),
          ),
        )
        .toList();
    return ScanPage(
      items,
      limit: limit,
      nextCursor: rows.length > limit
          ? '${items.last.type}:${items.last.id}'
          : null,
    );
  }

  @override
  Future<void> initializeNode(String id, int parentCount) => _write(
    'INSERT INTO graph_node(run_id,revision_id,remaining,processed) VALUES(?,?,?,0)',
    [runId, id, parentCount],
  );
  @override
  Future<bool> claimRoot(GraphEntity e, String id) async {
    if ((await _read(
      'SELECT 1 FROM graph_root WHERE run_id=? AND entity_type=? AND entity_id=?',
      [runId, e.type, e.id],
    )).isNotEmpty) {
      return false;
    }
    await _write('INSERT INTO graph_root VALUES(?,?,?,?)', [
      runId,
      e.type,
      e.id,
      id,
    ]);
    return true;
  }

  @override
  Future<String?> takeReady() => database.transaction(() async {
    final rows = await _read(
      'SELECT revision_id FROM graph_node WHERE run_id=? AND remaining=0 AND processed=0 ORDER BY revision_id LIMIT 1',
      [runId],
    );
    if (rows.isEmpty) return null;
    final id = rows.single.read<String>('revision_id');
    final envelope = (await findRevision(id))!.envelope;
    final inherited = (await _read(
      'SELECT COALESCE(MAX(n.standard_seen),0) seen FROM graph_edge e JOIN graph_node n ON n.run_id=e.run_id AND n.revision_id=e.parent_id WHERE e.run_id=? AND e.child_id=?',
      [runId, id],
    )).single.read<int>('seen');
    if (envelope.entityType == 'quotation' &&
        envelope.kind == 'put' &&
        inherited == 1 &&
        envelope.payload['capture_mode'] != 'standard') {
      throw const DomainFailure(
        'standard_downgrade',
        'Standard quotation ancestry cannot become historical',
      );
    }
    final standard =
        inherited == 1 ||
        (envelope.entityType == 'quotation' &&
            envelope.payload['capture_mode'] == 'standard');
    await _write(
      'UPDATE graph_node SET standard_seen=? WHERE run_id=? AND revision_id=?',
      [standard ? 1 : 0, runId, id],
    );

    await _write(
      'UPDATE graph_node SET processed=1 WHERE run_id=? AND revision_id=?',
      [runId, id],
    );
    return id;
  });
  @override
  Future<ScanPage<String>> readChildren(
    String parentId, {
    String? after,
    required int limit,
  }) async {
    checkLimit(limit);
    final rows = await _read(
      'SELECT child_id FROM graph_edge WHERE run_id=? AND parent_id=? AND child_id>? ORDER BY child_id LIMIT ?',
      [runId, parentId, after ?? '', limit + 1],
    );
    final items = rows
        .take(limit)
        .map((r) => r.read<String>('child_id'))
        .toList();
    return ScanPage(
      items,
      limit: limit,
      nextCursor: rows.length > limit ? items.last : null,
    );
  }

  @override
  Future<void> releaseParent(String id) async {
    await _usable();
    final changed = await database.customUpdate(
      'UPDATE graph_node SET remaining=remaining-1 WHERE run_id=? AND revision_id=? AND remaining>0 AND processed=0',
      variables: [Variable(runId), Variable(id)],
    );
    if (changed != 1) {
      throw StateError('Duplicate parent release or missing node');
    }
  }

  @override
  Future<void> recordHead(String id) async {
    await _write(
      'INSERT INTO graph_head SELECT run_id,entity_type,entity_id,revision_id FROM graph_revision WHERE run_id=? AND revision_id=?',
      [runId, id],
    );
    final row = (await findRevision(id))!;
    if (row.envelope.kind == 'redirect') {
      await _write(
        'INSERT INTO graph_redirect VALUES(?,?,?,?) ON CONFLICT(run_id,entity_type,source_id,target_id) DO NOTHING',
        [
          runId,
          row.entity.type,
          row.entity.id,
          row.envelope.payload['target_id'],
        ],
      );
    }
  }

  @override
  Future<GraphHeadSummary> headSummary(GraphEntity e) async {
    final count = (await _read(
      'SELECT COUNT(*) n FROM graph_head WHERE run_id=? AND entity_type=? AND entity_id=?',
      [runId, e.type, e.id],
    )).single.read<int>('n');
    final redirect = (await _read(
      'SELECT 1 FROM graph_redirect WHERE run_id=? AND entity_type=? AND source_id=? LIMIT 1',
      [runId, e.type, e.id],
    )).isNotEmpty;
    GraphRevision? single;
    if (count == 1) {
      single = await findRevision(
        (await _read(
          'SELECT revision_id FROM graph_head WHERE run_id=? AND entity_type=? AND entity_id=?',
          [runId, e.type, e.id],
        )).single.read<String>('revision_id'),
      );
    }
    return GraphHeadSummary(
      count: count,
      containsRedirect: redirect,
      single: single,
    );
  }

  GraphRelation _relation(QueryRow r) => GraphRelation(
    GraphRelationStatus.values.byName(r.read<String>('status')),
    canonical: r.readNullable<String>('canonical_id') == null
        ? null
        : GraphEntity(
            r.read<String>('entity_type'),
            r.read<String>('canonical_id'),
          ),
  );
  @override
  Future<GraphRelation?> relation(GraphEntity e) async {
    final rows = await _read(
      'SELECT * FROM graph_relation WHERE run_id=? AND entity_type=? AND entity_id=?',
      [runId, e.type, e.id],
    );
    return rows.isEmpty ? null : _relation(rows.single);
  }

  @override
  Future<String?> visitMarker(GraphEntity e) async {
    final rows = await _read(
      'SELECT marker FROM graph_walk WHERE run_id=? AND entity_type=? AND entity_id=?',
      [runId, e.type, e.id],
    );
    return rows.isEmpty ? null : rows.single.read<String>('marker');
  }

  @override
  Future<void> appendWalk(String marker, GraphEntity e) => _write(
    'INSERT INTO graph_walk VALUES(?,?,?,?)',
    [runId, e.type, e.id, marker],
  );
  @override
  Future<void> finishWalk(
    String marker,
    GraphRelation result,
  ) => database.transaction(() async {
    await _write(
      'INSERT INTO graph_relation SELECT run_id,entity_type,entity_id,?,? FROM graph_walk WHERE run_id=? AND marker=?',
      [result.status.name, result.canonical?.id, runId, marker],
    );
    await _write('DELETE FROM graph_walk WHERE run_id=? AND marker=?', [
      runId,
      marker,
    ]);
  });
  @override
  Future<ScanPage<GraphEntity>> readRedirectNeighbors(
    GraphEntity e, {
    String? after,
    required int limit,
  }) async {
    checkLimit(limit);
    final cursor = entityCursor(after);
    if (cursor.$1.compareTo(e.type) > 0) return ScanPage([], limit: limit);
    final afterId = cursor.$1 == e.type ? cursor.$2 : '';
    return _entities(
      'SELECT entity_type,target_id entity_id FROM graph_redirect WHERE run_id=? AND entity_type=? AND source_id=? AND target_id>? UNION SELECT entity_type,source_id entity_id FROM graph_redirect WHERE run_id=? AND entity_type=? AND target_id=? AND source_id>? ORDER BY entity_type,entity_id LIMIT ?',
      [runId, e.type, e.id, afterId, runId, e.type, e.id, afterId, limit + 1],
      limit,
    );
  }

  @override
  Future<void> enqueueAnomaly(
    GraphEntity e,
    GraphRelationStatus status,
  ) => database.transaction(() async {
    if (status != GraphRelationStatus.redirectCycle &&
        status != GraphRelationStatus.parallelRedirect) {
      throw ArgumentError('Not an anomaly');
    }
    final rank = status == GraphRelationStatus.redirectCycle ? 2 : 1;
    final previous = await _read(
      'SELECT rank FROM graph_anomaly WHERE run_id=? AND entity_type=? AND entity_id=?',
      [runId, e.type, e.id],
    );
    if (previous.isNotEmpty && previous.single.read<int>('rank') >= rank) {
      return;
    }
    await _write(
      'INSERT INTO graph_anomaly VALUES(?,?,?,?,1) ON CONFLICT(run_id,entity_type,entity_id) DO UPDATE SET rank=excluded.rank,pending=1',
      [runId, e.type, e.id, rank],
    );
    await _write(
      'INSERT INTO graph_relation VALUES(?,?,?,?,NULL) ON CONFLICT(run_id,entity_type,entity_id) DO UPDATE SET status=excluded.status,canonical_id=NULL',
      [runId, e.type, e.id, status.name],
    );
  });
  @override
  Future<(GraphEntity, GraphRelationStatus)?>
  takeAnomaly() => database.transaction(() async {
    final rows = await _read(
      'SELECT * FROM graph_anomaly WHERE run_id=? AND pending=1 ORDER BY entity_type,entity_id LIMIT 1',
      [runId],
    );
    if (rows.isEmpty) return null;
    final r = rows.single;
    final e = GraphEntity(
      r.read<String>('entity_type'),
      r.read<String>('entity_id'),
    );
    await _write(
      'UPDATE graph_anomaly SET pending=0 WHERE run_id=? AND entity_type=? AND entity_id=?',
      [runId, e.type, e.id],
    );
    return (
      e,
      r.read<int>('rank') == 2
          ? GraphRelationStatus.redirectCycle
          : GraphRelationStatus.parallelRedirect,
    );
  });
}

(String, String) entityCursor(String? value) {
  if (value == null) return ('', '');
  final at = value.indexOf(':');
  if (at < 1) throw ArgumentError('Invalid entity cursor');
  return (value.substring(0, at), value.substring(at + 1));
}

const graphWorkTables = [
  'graph_affected',
  'graph_anomaly',
  'graph_walk',
  'graph_relation',
  'graph_redirect',
  'graph_head',
  'graph_root',
  'graph_node',
  'graph_edge',
  'graph_entity',
  'graph_revision',
];
const graphSchema = <String>[
  'CREATE TABLE graph_affected(run_id TEXT NOT NULL,entity_type TEXT NOT NULL,entity_id TEXT NOT NULL,PRIMARY KEY(run_id,entity_type,entity_id))',
  'CREATE TABLE graph_run(run_id TEXT PRIMARY KEY,job_id TEXT NOT NULL,state TEXT NOT NULL)',
  'CREATE TABLE graph_revision(run_id TEXT NOT NULL,revision_id TEXT NOT NULL,entity_type TEXT NOT NULL,entity_id TEXT NOT NULL,canonical TEXT NOT NULL,PRIMARY KEY(run_id,revision_id))',
  'CREATE INDEX graph_revision_entity ON graph_revision(run_id,entity_type,entity_id,revision_id)',
  'CREATE TABLE graph_entity(run_id TEXT NOT NULL,entity_type TEXT NOT NULL,entity_id TEXT NOT NULL,PRIMARY KEY(run_id,entity_type,entity_id))',
  'CREATE TABLE graph_edge(run_id TEXT NOT NULL,child_id TEXT NOT NULL,parent_id TEXT NOT NULL,PRIMARY KEY(run_id,child_id,parent_id))',
  'CREATE INDEX graph_edge_parent ON graph_edge(run_id,parent_id,child_id)',
  'CREATE TABLE graph_node(run_id TEXT NOT NULL,revision_id TEXT NOT NULL,remaining INTEGER NOT NULL CHECK(remaining>=0),processed INTEGER NOT NULL,standard_seen INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(run_id,revision_id))',
  'CREATE INDEX graph_ready ON graph_node(run_id,remaining,processed,revision_id)',
  'CREATE TABLE graph_root(run_id TEXT NOT NULL,entity_type TEXT NOT NULL,entity_id TEXT NOT NULL,revision_id TEXT NOT NULL,PRIMARY KEY(run_id,entity_type,entity_id))',
  'CREATE TABLE graph_head(run_id TEXT NOT NULL,entity_type TEXT NOT NULL,entity_id TEXT NOT NULL,revision_id TEXT NOT NULL,PRIMARY KEY(run_id,entity_type,entity_id,revision_id))',
  'CREATE TABLE graph_redirect(run_id TEXT NOT NULL,entity_type TEXT NOT NULL,source_id TEXT NOT NULL,target_id TEXT NOT NULL,PRIMARY KEY(run_id,entity_type,source_id,target_id))',
  'CREATE INDEX graph_redirect_reverse ON graph_redirect(run_id,entity_type,target_id,source_id)',
  'CREATE TABLE graph_relation(run_id TEXT NOT NULL,entity_type TEXT NOT NULL,entity_id TEXT NOT NULL,status TEXT NOT NULL,canonical_id TEXT,PRIMARY KEY(run_id,entity_type,entity_id))',
  'CREATE TABLE graph_walk(run_id TEXT NOT NULL,entity_type TEXT NOT NULL,entity_id TEXT NOT NULL,marker TEXT NOT NULL,PRIMARY KEY(run_id,entity_type,entity_id))',
  'CREATE INDEX graph_walk_marker ON graph_walk(run_id,marker)',
  'CREATE TABLE graph_anomaly(run_id TEXT NOT NULL,entity_type TEXT NOT NULL,entity_id TEXT NOT NULL,rank INTEGER NOT NULL,pending INTEGER NOT NULL,PRIMARY KEY(run_id,entity_type,entity_id))',
  'CREATE INDEX graph_anomaly_pending ON graph_anomaly(run_id,pending,entity_type,entity_id)',
];
