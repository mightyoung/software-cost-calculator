import '../contracts.dart';
import 'revision.dart';

/// Identity of the local + sealed incoming union, captured before any graph read.
final class GraphBinding {
  const GraphBinding({
    required this.database,
    required this.jobId,
    required this.sealedDigest,
  });
  final DatabaseVersion database;
  final String jobId, sealedDigest;
  bool sameAs(GraphBinding other) =>
      database.instanceId == other.database.instanceId &&
      database.activeEpoch == other.database.activeEpoch &&
      database.generation == other.database.generation &&
      jobId == other.jobId &&
      sealedDigest == other.sealedDigest;
}

final class GraphEntity {
  const GraphEntity(this.type, this.id);
  final String type, id;
  @override
  bool operator ==(Object other) =>
      other is GraphEntity && type == other.type && id == other.id;
  @override
  int get hashCode => Object.hash(type, id);
}

/// Input adapters must have verified the canonical envelope hash, normalized
/// payload and collision-free revision set BEFORE exposing this source. This
/// graph algorithm checks relationships, not serialization/hash correctness.
final class GraphRevision {
  const GraphRevision(this.id, this.envelope);
  final String id;
  final RevisionEnvelope envelope;
  GraphEntity get entity => GraphEntity(envelope.entityType, envelope.entityId);
}

final class GraphHeadSummary {
  const GraphHeadSummary({
    required this.count,
    required this.containsRedirect,
    this.single,
  });
  final int count;
  final bool containsRedirect;

  /// Populated exactly when count == 1, never a whole per-entity history list.
  final GraphRevision? single;
}

enum GraphRelationStatus {
  active,
  deleted,
  conflicted,
  redirectCycle,
  parallelRedirect,
}

final class GraphRelation {
  const GraphRelation(this.status, {this.canonical});
  final GraphRelationStatus status;

  /// Absent for ambiguous or cyclic components. Tombstones remain resolvable.
  final GraphEntity? canonical;
}

/// Storage port for a SINGLE exclusive validation run. Production implementers
/// must use persistent indexed work tables, not whole-graph Maps/Lists.
///
/// Source methods expose the union of local history and sealed staging, with
/// identical revisions deduplicated. They must never silently rebind versions.
/// Source ordering is stable, binary revision-id / (type,id) keyset order. Pages
/// contain at most limit items; nextCursor is null exactly at end, otherwise a
/// strictly lexicographically increasing cursor. Lookups are indexed and bounded.
///
/// Work state is isolated by run/job. resetWork erases previous run results and
/// binds the supplied identity. discardWork erases ALL indegrees, ready queue,
/// roots, heads, visits, paths, anomaly queues/marks, and relation results, never source/business rows.
/// If discardWork fails, the adapter MUST persistently quarantine that run:
/// reject reuse/reset and publication of its retained results until an explicit
/// recovery has verified complete cleanup (including across process restart).
/// Throwing graph_cleanup_failed alone does not enforce this storage duty.
/// Failed or interrupted runs cannot be reused. Successful output is retained
/// for paged inspection, but is NOT a trusted commit token or projection commit.
abstract interface class GraphWorkspace {
  Future<GraphBinding> currentBinding();
  Future<void> resetWork(GraphBinding binding);
  Future<void> discardWork();
  Future<ScanPage<GraphRevision>> readRevisions({
    String? after,
    required int limit,
  });
  Future<GraphRevision?> findRevision(String id);
  Future<bool> hasEntity(GraphEntity entity);
  Future<ScanPage<GraphEntity>> readEntities({
    String? after,
    required int limit,
  });

  /// Initialize once per revision, with parents.length outstanding edges; if
  /// zero, enqueue once. No source rows may change as a side effect.
  Future<void> initializeNode(String revisionId, int parentCount);

  /// Record first root, return false if any root already exists for this entity.
  Future<bool> claimRoot(GraphEntity entity, String revisionId);

  /// Remove one ready node and mark processed atomically, or null when empty.
  Future<String?> takeReady();
  Future<ScanPage<String>> readChildren(
    String parentId, {
    String? after,
    required int limit,
  });

  /// Decrement exactly once for this processed parent edge, enqueue when zero;
  /// underflow/duplicate processing must throw. No in-memory unbounded queue.
  Future<void> releaseParent(String childId);
  Future<void> recordHead(String revisionId);
  Future<GraphHeadSummary> headSummary(GraphEntity entity);

  Future<GraphRelation?> relation(GraphEntity entity);

  /// Persistent walk membership; marker is unique per walk in this reset run.
  Future<String?> visitMarker(GraphEntity entity);
  Future<void> appendWalk(String marker, GraphEntity entity);

  /// Assign result to every member of this marker using storage-side update or
  /// bounded scans, then delete that walk. Do not return its members as a List.
  Future<void> finishWalk(String marker, GraphRelation result);

  /// Current-head redirect edges only, in BOTH directions, deduplicated and
  /// indexed by entity. Historical superseded redirect edges MUST be excluded.
  Future<ScanPage<GraphEntity>> readRedirectNeighbors(
    GraphEntity entity, {
    String? after,
    required int limit,
  });

  /// Persist mark + queue entry only on new/stronger anomaly, overwrite relation
  /// with no canonical winner. Detected single-successor redirectCycle results
  /// dominate parallelRedirect; each entity queues at most twice. Traversal
  /// stops at parallel heads, so cycles crossing a branch may be classified as
  /// parallelRedirect. Both exclude the entire component from normal use.
  /// Other statuses are invalid. Marks are separate from memoized results.
  Future<void> enqueueAnomaly(GraphEntity entity, GraphRelationStatus status);
  Future<(GraphEntity, GraphRelationStatus)?> takeAnomaly();
}

/// Diagnostic output only: does not extend ValidatedChangeSet, authorize writes,
/// select conflict winners, or install a production RecordService.
final class GraphValidationReport {
  const GraphValidationReport({
    required this.binding,
    required this.revisions,
    required this.entities,
    required this.heads,
    required this.anomalousEntities,
  });
  final GraphBinding binding;
  final int revisions, entities, heads, anomalousEntities;
}

final class RevisionGraphValidator {
  RevisionGraphValidator({this.pageSize = 500}) {
    if (pageSize < 1 || pageSize > 5000) {
      throw ArgumentError.value(pageSize, 'pageSize');
    }
  }
  final int pageSize;

  Future<GraphValidationReport> validate(GraphWorkspace work) async {
    // Binding precedes reset and every source read; never replace it at end.
    try {
      final binding = await work.currentBinding();
      await work.resetWork(binding);
      var revisions = 0, entities = 0, heads = 0, anomalous = 0;
      String? cursor;
      do {
        final page = await work.readRevisions(after: cursor, limit: pageSize);
        _checkPage(page, cursor);
        for (final row in page.items) {
          revisions++;
          final envelope = row.envelope;
          if (envelope.parents.isEmpty) {
            if (envelope.kind != 'put') _fail('graph_root_kind', row.id);
            if (!await work.claimRoot(row.entity, row.id)) {
              _fail('graph_multiple_roots', row.id);
            }
          }
          for (final parentId in envelope.parents) {
            final parent = await work.findRevision(parentId);
            if (parent == null) _fail('graph_missing_parent', parentId);
            if (parent.entity != row.entity) {
              _fail('graph_parent_entity', parentId);
            }
          }
          for (final reference in _references(row)) {
            if (!await work.hasEntity(reference)) {
              _fail(
                'graph_missing_reference',
                '${reference.type}:${reference.id}',
              );
            }
          }
          await work.initializeNode(row.id, envelope.parents.length);
        }
        cursor = page.nextCursor;
      } while (cursor != null);

      var processed = 0;
      while (true) {
        final id = await work.takeReady();
        if (id == null) break;
        processed++;
        var hasChildren = false;
        cursor = null;
        do {
          final page = await work.readChildren(
            id,
            after: cursor,
            limit: pageSize,
          );
          _checkPage(page, cursor);
          hasChildren = hasChildren || page.items.isNotEmpty;
          for (final child in page.items) {
            await work.releaseParent(child);
          }
          cursor = page.nextCursor;
        } while (cursor != null);
        if (!hasChildren) {
          await work.recordHead(id);
          heads++;
        }
      }
      if (processed != revisions) {
        _fail('graph_cycle', 'Unprocessed revisions: ${revisions - processed}');
      }

      cursor = null;
      do {
        final page = await work.readEntities(after: cursor, limit: pageSize);
        _checkPage(page, cursor);
        for (final entity in page.items) {
          entities++;
          final result = await _resolve(work, entity, 'walk-$entities');
          if (_isAnomalous(result.status)) {
            await work.enqueueAnomaly(entity, result.status);
          }
        }
        cursor = page.nextCursor;
      } while (cursor != null);
      while (true) {
        final pending = await work.takeAnomaly();
        if (pending == null) break;
        cursor = null;
        do {
          final page = await work.readRedirectNeighbors(
            pending.$1,
            after: cursor,
            limit: pageSize,
          );
          _checkPage(page, cursor);
          for (final neighbor in page.items) {
            await work.enqueueAnomaly(neighbor, pending.$2);
          }
          cursor = page.nextCursor;
        } while (cursor != null);
      }
      cursor = null;
      do {
        final page = await work.readEntities(after: cursor, limit: pageSize);
        _checkPage(page, cursor);
        for (final entity in page.items) {
          final relation = await work.relation(entity);
          if (relation == null) {
            _fail('graph_workspace_contract', 'Missing relation result');
          }
          if (_isAnomalous(relation.status)) anomalous++;
        }
        cursor = page.nextCursor;
      } while (cursor != null);
      if (!binding.sameAs(await work.currentBinding())) {
        _fail(
          'graph_stale_binding',
          'Database or sealed staging changed during scan',
        );
      }
      return GraphValidationReport(
        binding: binding,
        revisions: revisions,
        entities: entities,
        heads: heads,
        anomalousEntities: anomalous,
      );
    } catch (primary, primaryStack) {
      try {
        await work.discardWork();
      } catch (cleanup, cleanupStack) {
        throw DomainFailure(
          'graph_cleanup_failed',
          'Graph validation failed and its workspace could not be cleared; '
              'the adapter must quarantine this run',
          cause: (
            primary: primary,
            primaryStack: primaryStack,
            cleanup: cleanup,
            cleanupStack: cleanupStack,
          ),
        );
      }
      rethrow;
    }
  }

  Future<GraphRelation> _resolve(
    GraphWorkspace work,
    GraphEntity start,
    String marker,
  ) async {
    var current = start;
    late GraphRelation result;
    while (true) {
      final resolved = await work.relation(current);
      if (resolved != null) {
        result = resolved;
        break;
      }
      if (await work.visitMarker(current) == marker) {
        result = const GraphRelation(GraphRelationStatus.redirectCycle);
        break;
      }
      await work.appendWalk(marker, current);
      final summary = await work.headSummary(current);
      if (summary.count < 1) _fail('graph_missing_head', current.id);
      if (summary.count > 1) {
        result = GraphRelation(
          summary.containsRedirect
              ? GraphRelationStatus.parallelRedirect
              : GraphRelationStatus.conflicted,
        );
        break;
      }
      final head = summary.single;
      if (head == null) {
        _fail('graph_workspace_contract', 'Missing single head');
      }
      switch (head.envelope.kind) {
        case 'redirect':
          current = GraphEntity(
            current.type,
            head.envelope.payload['target_id']! as String,
          );
        case 'delete':
          result = GraphRelation(
            GraphRelationStatus.deleted,
            canonical: current,
          );
        case 'put':
          result = GraphRelation(
            GraphRelationStatus.active,
            canonical: current,
          );
      }
      if (head.envelope.kind != 'redirect') break;
    }
    await work.finishWalk(marker, result);
    return result;
  }

  Iterable<GraphEntity> _references(GraphRevision row) sync* {
    final envelope = row.envelope;
    final payload = envelope.payload;
    if (envelope.kind == 'redirect') {
      yield GraphEntity(envelope.entityType, payload['target_id']! as String);
    } else if (envelope.kind == 'put') {
      if (envelope.entityType == 'contact' ||
          envelope.entityType == 'quotation') {
        yield GraphEntity('supplier', payload['supplier_id']! as String);
      }
      if (envelope.entityType == 'quotation') {
        yield GraphEntity('product', payload['product_id']! as String);
        if (payload['contact_id'] != null) {
          yield GraphEntity('contact', payload['contact_id']! as String);
        }
      }
    }
  }

  bool _isAnomalous(GraphRelationStatus status) =>
      status == GraphRelationStatus.redirectCycle ||
      status == GraphRelationStatus.parallelRedirect;

  void _checkPage<T>(ScanPage<T> page, String? previous) {
    if (page.items.length > pageSize ||
        (page.nextCursor != null &&
            previous != null &&
            page.nextCursor!.compareTo(previous) <= 0)) {
      _fail(
        'graph_workspace_contract',
        'Oversized page or nonadvancing cursor',
      );
    }
  }

  Never _fail(String code, String message) =>
      throw DomainFailure(code, message);
}
