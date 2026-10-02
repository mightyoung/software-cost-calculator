import 'dart:convert';
import 'package:drift/drift.dart';
import '../contracts.dart';
import '../domain/revision.dart';
import '../domain/revision_graph.dart';
import 'database.dart';

/// Persistent indexed workspace, isolated by a non-reusable run identity.
/// It is diagnostic storage, never itself a commit authorization.
class SqlGraphWorkspace
    implements
        GraphWorkspace,
        BatchedGraphWorkspace,
        PagedGraphWorkspace,
        TerminalGraphWorkspace,
        PagedRelationGraphWorkspace {
  SqlGraphWorkspace(
    this.database, {
    required this.jobId,
    required this.runId,
    this.phaseObserver,
  });
  final SupplierDatabase database;
  final String jobId, runId;
  final void Function(String phase)? phaseObserver;
  int _initializedRows = 0;
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
      phaseObserver?.call('local_revisions_copied');
      await _write(
        'INSERT INTO graph_revision SELECT ?,revision_id,json_extract(canonical,\'\$.entity_type\'),json_extract(canonical,\'\$.entity_id\'),canonical FROM staging_revision WHERE job_id=? ON CONFLICT(run_id,revision_id) DO NOTHING',
        [runId, jobId],
      );
      phaseObserver?.call('staged_revisions_copied');
      await _write(
        'INSERT INTO graph_entity SELECT DISTINCT run_id,entity_type,entity_id FROM graph_revision WHERE run_id=?',
        [runId],
      );
      phaseObserver?.call('entities_copied');
      await _write(
        'INSERT INTO graph_edge SELECT r.run_id,r.revision_id,p.value FROM graph_revision r,json_each(r.canonical,\'\$.parents\') p WHERE r.run_id=?',
        [runId],
      );
      phaseObserver?.call('edges_copied');
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
  Future<void> initializePage(List<GraphRevision> rows) async {
    if (rows.isEmpty) return;
    checkLimit(rows.length);
    await database.transaction(() async {
      // Traverse edges lazily in scalar validation order. Never retain the
      // canonical envelopes of a page's entire parent closure: a page can
      // contain thousands of high-fan-in merges.
      Iterable<String> parentIds() sync* {
        for (final row in rows) {
          yield* row.envelope.parents;
        }
      }

      final parentCursor = parentIds().iterator;
      var parents = <String, QueryRow>{};
      var bufferedEdges = 0;
      final references = {for (final row in rows) ...row.references};
      // Keep the bounded JSON keys outermost so SQLite probes the complete
      // (run, type, id) primary key instead of rescanning this run each page.
      final entityRows = await _read(
        '''SELECT e.entity_type,e.entity_id FROM json_each(?) j
        CROSS JOIN graph_entity e ON e.entity_type=json_extract(j.value,'\$.type')
        AND e.entity_id=json_extract(j.value,'\$.id') WHERE e.run_id=?''',
        [
          jsonEncode([
            for (final e in references) {'type': e.type, 'id': e.id},
          ]),
          runId,
        ],
      );
      final existing = {
        for (final row in entityRows)
          GraphEntity(
            row.read<String>('entity_type'),
            row.read<String>('entity_id'),
          ),
      };
      final rootRows = await _read(
        '''SELECT r.entity_type,r.entity_id FROM json_each(?) j
        CROSS JOIN graph_root r ON r.entity_type=json_extract(j.value,'\$.type')
        AND r.entity_id=json_extract(j.value,'\$.id') WHERE r.run_id=?''',
        [
          jsonEncode([
            for (final row in rows)
              if (row.envelope.parents.isEmpty)
                {'type': row.entity.type, 'id': row.entity.id},
          ]),
          runId,
        ],
      );
      final roots = {
        for (final row in rootRows)
          GraphEntity(
            row.read<String>('entity_type'),
            row.read<String>('entity_id'),
          ),
      };
      for (final row in rows) {
        if (row.envelope.parents.isEmpty) {
          if (row.envelope.kind != 'put') {
            throw DomainFailure('graph_root_kind', row.id);
          }
          if (!roots.add(row.entity)) {
            throw DomainFailure('graph_multiple_roots', row.id);
          }
        }
        for (final id in row.envelope.parents) {
          if (bufferedEdges == 0) {
            // Drop the old batch before awaiting the next query. At most 64
            // parent canonical envelopes are retained, independent of fan-in.
            parents = {};
            final ids = <String>[];
            while (ids.length < 64 && parentCursor.moveNext()) {
              ids.add(parentCursor.current);
            }
            final fetched = await _read(
              'SELECT * FROM graph_revision WHERE run_id=? AND revision_id IN (SELECT value FROM json_each(?))',
              [runId, jsonEncode(ids)],
            );
            parents = {
              for (final raw in fetched) raw.read<String>('revision_id'): raw,
            };
            bufferedEdges = ids.length;
          }
          bufferedEdges--;
          final raw = parents[id];
          if (raw == null) throw DomainFailure('graph_missing_parent', id);
          if (_revision(raw).entity != row.entity) {
            throw DomainFailure('graph_parent_entity', id);
          }
        }
        for (final reference in row.references) {
          if (!existing.contains(reference)) {
            throw DomainFailure(
              'graph_missing_reference',
              '${reference.type}:${reference.id}',
            );
          }
        }
      }
      final encoded = jsonEncode([
        for (final row in rows)
          {
            'id': row.id,
            'type': row.entity.type,
            'entity': row.entity.id,
            'parents': row.envelope.parents.length,
          },
      ]);
      await _write(
        '''INSERT INTO graph_root SELECT ?,json_extract(value,'\$.type'),json_extract(value,'\$.entity'),json_extract(value,'\$.id') FROM json_each(?) WHERE json_extract(value,'\$.parents')=0''',
        [runId, encoded],
      );
      await _write(
        '''INSERT INTO graph_node(run_id,revision_id,remaining,processed) SELECT ?,json_extract(value,'\$.id'),json_extract(value,'\$.parents'),0 FROM json_each(?)''',
        [runId, encoded],
      );
    });
    _initializedRows += rows.length;
    if (_initializedRows % 10000 == 0) {
      phaseObserver?.call('initialized_$_initializedRows');
    }
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
  Future<({int processed, int heads})> processReadyBatch(
    int limit,
  ) => database.transaction(() async {
    checkLimit(limit);
    final ready = await _read(
      'SELECT revision_id FROM graph_node WHERE run_id=? AND remaining=0 AND processed=0 ORDER BY revision_id LIMIT ?',
      [runId, limit],
    );
    if (ready.isEmpty) return (processed: 0, heads: 0);
    // One JSON parameter keeps the frontier bounded without depending on
    // the platform SQLite host-parameter limit.
    final ids = jsonEncode(
      ready.map((r) => r.read<String>('revision_id')).toList(),
    );
    const selected = 'SELECT value FROM json_each(?)';
    const inherited = '''EXISTS (
          SELECT 1 FROM graph_edge e JOIN graph_node p
          ON p.run_id=e.run_id AND p.revision_id=e.parent_id
          WHERE e.run_id=n.run_id AND e.child_id=n.revision_id
          AND p.standard_seen=1)''';
    // Decode wide canonical rows once for this bounded frontier. Keep SQL's
    // null/comparison semantics when deriving the two quotation predicates.
    final metadataRows = await _read(
      '''SELECT j.value revision_id,r.entity_type,r.entity_id,
          CASE WHEN r.entity_type='quotation'
            AND json_extract(r.canonical,'\$.kind')='put'
            AND COALESCE(json_extract(r.canonical,'\$.payload.capture_mode'),'')<>'standard'
            THEN 1 ELSE 0 END downgrade_candidate,
          CASE WHEN r.entity_type='quotation'
            AND json_extract(r.canonical,'\$.payload.capture_mode')='standard'
            THEN 1 ELSE 0 END own_standard,
          json_extract(r.canonical,'\$.kind') kind,
          json_extract(r.canonical,'\$.payload.target_id') target_id
          FROM json_each(?) j LEFT JOIN graph_revision r
          ON r.run_id=? AND r.revision_id=j.value''',
      [ids, runId],
    );
    final metadata = metadataRows.map((row) => row.data).toList();
    final metadataJson = jsonEncode(metadata);
    final downgrade = await _read(
      '''
          SELECT 1 FROM json_each(?) j CROSS JOIN graph_node n
          ON n.run_id=? AND n.revision_id=json_extract(j.value,'\$.revision_id')
          WHERE json_extract(j.value,'\$.downgrade_candidate')=1
          AND $inherited LIMIT 1''',
      [metadataJson, runId],
    );
    if (downgrade.isNotEmpty) {
      throw const DomainFailure(
        'standard_downgrade',
        'Standard quotation ancestry cannot become historical',
      );
    }
    await _write(
      '''WITH selected AS MATERIALIZED (
            SELECT json_extract(value,'\$.revision_id') revision_id,
              json_extract(value,'\$.own_standard') own_standard
            FROM json_each(?))
          UPDATE graph_node AS n INDEXED BY sqlite_autoindex_graph_node_1
          SET processed=1, standard_seen=
          CASE WHEN $inherited OR s.own_standard=1
          THEN 1 ELSE 0 END
          FROM selected s WHERE n.run_id=? AND n.revision_id=s.revision_id
          AND n.revision_id IN (SELECT revision_id FROM selected)''',
      [metadataJson, runId],
    );
    // Ready nodes cannot be ancestors of one another. Grouping edges is
    // therefore equivalent to releasing each selected parent individually.
    const releases = '''SELECT child_id, COUNT(*) amount
          FROM graph_edge INDEXED BY graph_edge_parent
          WHERE run_id=? AND parent_id IN ($selected) GROUP BY child_id''';
    final invalid = await _read(
      '''WITH releases AS ($releases)
          SELECT 1 FROM releases e LEFT JOIN graph_node n
          ON n.run_id=? AND n.revision_id=e.child_id
          WHERE n.revision_id IS NULL OR n.processed<>0 OR n.remaining<e.amount
          LIMIT 1''',
      [runId, ids, runId],
    );
    if (invalid.isNotEmpty) {
      throw StateError('Duplicate parent release or missing node');
    }
    await _write(
      '''WITH releases AS ($releases)
          UPDATE graph_node INDEXED BY sqlite_autoindex_graph_node_1
          SET remaining=remaining-e.amount FROM releases e
          WHERE graph_node.run_id=? AND graph_node.revision_id=e.child_id
          AND graph_node.revision_id IN (SELECT child_id FROM releases)''',
      [runId, ids, runId],
    );
    final terminals = await _read(
      '''SELECT j.key ordinal FROM json_each(?) j
          WHERE json_extract(j.value,'\$.entity_type') IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM graph_edge e
            WHERE e.run_id=?
            AND e.parent_id=json_extract(j.value,'\$.revision_id'))''',
      [metadataJson, runId],
    );
    if (terminals.isEmpty) {
      return (processed: ready.length, heads: 0);
    }
    final headMetadata = jsonEncode(
      terminals.map((r) => metadata[r.read<int>('ordinal')]).toList(),
    );
    await _write(
      '''INSERT INTO graph_head
          SELECT ?,json_extract(value,'\$.entity_type'),
            json_extract(value,'\$.entity_id'),json_extract(value,'\$.revision_id')
          FROM json_each(?)''',
      [runId, headMetadata],
    );
    await _write(
      '''INSERT INTO graph_redirect
          SELECT ?,json_extract(value,'\$.entity_type'),
            json_extract(value,'\$.entity_id'),json_extract(value,'\$.target_id')
          FROM json_each(?) WHERE json_extract(value,'\$.kind')='redirect'
          ON CONFLICT(run_id,entity_type,source_id,target_id) DO NOTHING''',
      [runId, headMetadata],
    );
    return (processed: ready.length, heads: terminals.length);
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
  Future<bool> supportsTerminalPages() async => (await _read(
    'SELECT 1 FROM graph_redirect WHERE run_id=? LIMIT 1',
    [runId],
  )).isEmpty;

  @override
  Future<void> resolveTerminalPage(List<GraphEntity> entities) async {
    if (entities.isEmpty) return;
    checkLimit(entities.length);
    await database.transaction(() async {
      final rows = await _read(
        '''
        WITH selected AS (
          SELECT CAST(key AS INTEGER) ordinal,
            json_extract(value,'\$.type') entity_type,
            json_extract(value,'\$.id') entity_id FROM json_each(?)
        )
        SELECT s.ordinal,
          (SELECT COUNT(*) FROM graph_head h WHERE h.run_id=?
            AND h.entity_type=s.entity_type AND h.entity_id=s.entity_id) n,
          (SELECT h.revision_id FROM graph_head h WHERE h.run_id=?
            AND h.entity_type=s.entity_type AND h.entity_id=s.entity_id
            LIMIT 1) single_id
        FROM selected s ORDER BY s.ordinal
      ''',
        [
          jsonEncode([
            for (final e in entities) {'type': e.type, 'id': e.id},
          ]),
          runId,
          runId,
        ],
      );
      for (var i = 0; i < rows.length; i++) {
        final row = rows[i];
        final entity = entities[i];
        final count = row.read<int>('n');
        var status = GraphRelationStatus.conflicted;
        String? canonical;
        if (count == 0) throw DomainFailure('graph_missing_head', entity.id);
        if (count == 1) {
          // Decode exactly one entity's head, then publish its relation before
          // decoding the next entity. This preserves insert/hash error order.
          final revision = await findRevision(row.read<String>('single_id'));
          if (revision == null) {
            throw const DomainFailure(
              'graph_workspace_contract',
              'Missing single head',
            );
          }
          if (revision.envelope.kind == 'redirect') {
            throw const DomainFailure(
              'graph_workspace_contract',
              'Unexpected terminal redirect',
            );
          }
          status = revision.envelope.kind == 'delete'
              ? GraphRelationStatus.deleted
              : GraphRelationStatus.active;
          canonical = entity.id;
        }
        await _write('INSERT INTO graph_relation VALUES(?,?,?,?,?)', [
          runId,
          entity.type,
          entity.id,
          status.name,
          canonical,
        ]);
      }
    });
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
  Future<List<GraphRelation?>> relationsPage(List<GraphEntity> entities) async {
    if (entities.isEmpty) return [];
    checkLimit(entities.length);
    final rows = await _read(
      '''SELECT j.key ordinal,r.entity_type,r.entity_id,r.status,r.canonical_id
        FROM json_each(?) j LEFT JOIN graph_relation r
        ON r.run_id=? AND r.entity_type=json_extract(j.value,'\$.type')
        AND r.entity_id=json_extract(j.value,'\$.id')
        ORDER BY CAST(j.key AS INTEGER)''',
      [
        jsonEncode([
          for (final entity in entities) {'type': entity.type, 'id': entity.id},
        ]),
        runId,
      ],
    );
    if (rows.length != entities.length) {
      throw const DomainFailure(
        'graph_workspace_contract',
        'Relation page size differs',
      );
    }
    return [
      for (final row in rows)
        row.readNullable<String>('status') == null ? null : _relation(row),
    ];
  }

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
