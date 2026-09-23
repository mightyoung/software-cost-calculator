import 'dart:collection';

import 'package:supplier_core/src/contracts.dart';
import 'package:supplier_core/src/domain/revision_graph.dart';

/// Small fixture / oracle adapter ONLY. Its in-memory structures are forbidden
/// for a production GraphWorkspace implementation and prove no disk/RSS bound.
final class MemoryGraphWorkspace implements GraphWorkspace {
  MemoryGraphWorkspace(Iterable<GraphRevision> source)
    : nodes = {for (final row in source) row.id: row} {
    sortedNodes = nodes.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    sortedEntities = nodes.values.map((row) => row.entity).toSet().toList()
      ..sort((a, b) => entityKey(a).compareTo(entityKey(b)));
    for (final row in sortedNodes) {
      for (final parent in row.envelope.parents) {
        (children[parent] ??= []).add(row.id);
      }
    }
  }
  final Map<String, GraphRevision> nodes;
  late final List<GraphRevision> sortedNodes;
  late final List<GraphEntity> sortedEntities;
  final Map<String, List<String>> children = {};
  final Map<String, int> remaining = {};
  final Queue<String> ready = Queue();
  final Set<String> processed = {};
  final Map<GraphEntity, String> roots = {};
  final Set<String> heads = {};
  final Map<GraphEntity, List<String>> entityHeads = {};
  final Map<GraphEntity, GraphRelation> relations = {};
  final Map<GraphEntity, Set<GraphEntity>> neighbors = {};
  final Map<GraphEntity, GraphRelationStatus> anomalyMarks = {};
  final Queue<(GraphEntity, GraphRelationStatus)> anomalyQueue = Queue();
  final Map<GraphEntity, String> visits = {};
  final Map<String, List<GraphEntity>> walks = {};
  GraphBinding binding = const GraphBinding(
    database: DatabaseVersion(
      instanceId: 'database',
      activeEpoch: 1,
      generation: 3,
    ),
    jobId: 'job',
    sealedDigest: 'sealed',
  );
  GraphBinding? bound;
  int sourceReads = 0, maxReturnedPage = 0, discarded = 0, bindingReads = 0;
  void Function(MemoryGraphWorkspace)? onRead;
  void Function(MemoryGraphWorkspace)? onBinding;
  Object? discardError;
  StackTrace? discardStack;
  bool quarantined = false;

  void _ensureUsable() {
    if (quarantined) throw StateError('Workspace is quarantined');
  }

  static String entityKey(GraphEntity entity) => '${entity.type}:${entity.id}';

  void _read() {
    _ensureUsable();
    if (bound == null) throw StateError('Source read before binding');
    sourceReads++;
    onRead?.call(this);
  }

  ScanPage<T> _page<T>(
    List<T> values,
    String Function(T) key,
    String? after,
    int limit,
  ) {
    final start = after == null
        ? 0
        : values.indexWhere((value) => key(value).compareTo(after) > 0);
    if (start < 0) return ScanPage([], limit: limit);
    final end = (start + limit).clamp(0, values.length);
    final result = values.sublist(start, end);
    if (result.length > maxReturnedPage) maxReturnedPage = result.length;
    return ScanPage(
      result,
      limit: limit,
      nextCursor: end < values.length ? key(result.last) : null,
    );
  }

  @override
  Future<GraphBinding> currentBinding() async {
    _ensureUsable();
    bindingReads++;
    onBinding?.call(this);
    return binding;
  }

  @override
  Future<void> resetWork(GraphBinding binding) async {
    _ensureUsable();
    await discardWork();
    discarded = 0;
    bound = binding;
  }

  @override
  Future<void> discardWork() async {
    final error = discardError;
    if (error != null) {
      quarantined = true;
      Error.throwWithStackTrace(error, discardStack ?? StackTrace.current);
    }
    neighbors.clear();
    anomalyMarks.clear();
    anomalyQueue.clear();
    remaining.clear();
    ready.clear();
    processed.clear();
    roots.clear();
    heads.clear();
    entityHeads.clear();
    relations.clear();
    visits.clear();
    walks.clear();
    bound = null;
    discarded++;
  }

  @override
  Future<ScanPage<GraphRevision>> readRevisions({
    String? after,
    required int limit,
  }) async {
    _read();
    return _page(sortedNodes, (row) => row.id, after, limit);
  }

  @override
  Future<GraphRevision?> findRevision(String id) async {
    _read();
    return nodes[id];
  }

  @override
  Future<bool> hasEntity(GraphEntity entity) async {
    _read();
    return sortedEntities.contains(entity);
  }

  @override
  Future<ScanPage<GraphEntity>> readEntities({
    String? after,
    required int limit,
  }) async {
    _read();
    return _page(sortedEntities, entityKey, after, limit);
  }

  @override
  Future<void> initializeNode(String revisionId, int parentCount) async {
    if (remaining.containsKey(revisionId)) {
      throw StateError('Duplicate source revision');
    }
    remaining[revisionId] = parentCount;
    if (parentCount == 0) ready.addLast(revisionId);
  }

  @override
  Future<bool> claimRoot(GraphEntity entity, String revisionId) async {
    if (roots.containsKey(entity)) return false;
    roots[entity] = revisionId;
    return true;
  }

  @override
  Future<String?> takeReady() async {
    if (ready.isEmpty) return null;
    final value = ready.removeFirst();
    if (!processed.add(value)) throw StateError('Duplicate process');
    return value;
  }

  @override
  Future<ScanPage<String>> readChildren(
    String parentId, {
    String? after,
    required int limit,
  }) async {
    _read();
    return _page(children[parentId] ?? [], (id) => id, after, limit);
  }

  @override
  Future<void> releaseParent(String childId) async {
    final next = remaining[childId]! - 1;
    if (next < 0) throw StateError('Indegree underflow');
    remaining[childId] = next;
    if (next == 0) ready.addLast(childId);
  }

  @override
  Future<void> recordHead(String revisionId) async {
    heads.add(revisionId);
    final row = nodes[revisionId]!;
    if (row.envelope.kind == 'redirect') {
      final target = GraphEntity(
        row.entity.type,
        row.envelope.payload['target_id']! as String,
      );
      (neighbors[row.entity] ??= {}).add(target);
      (neighbors[target] ??= {}).add(row.entity);
    }
    (entityHeads[nodes[revisionId]!.entity] ??= []).add(revisionId);
  }

  @override
  Future<GraphHeadSummary> headSummary(GraphEntity entity) async {
    final ids = entityHeads[entity] ?? [];
    return GraphHeadSummary(
      count: ids.length,
      containsRedirect: ids.any((id) => nodes[id]!.envelope.kind == 'redirect'),
      single: ids.length == 1 ? nodes[ids.single] : null,
    );
  }

  @override
  Future<GraphRelation?> relation(GraphEntity entity) async =>
      relations[entity];
  @override
  Future<String?> visitMarker(GraphEntity entity) async => visits[entity];
  @override
  Future<void> appendWalk(String marker, GraphEntity entity) async {
    visits[entity] = marker;
    (walks[marker] ??= []).add(entity);
  }

  @override
  Future<void> finishWalk(String marker, GraphRelation result) async {
    for (final entity in walks.remove(marker) ?? <GraphEntity>[]) {
      relations[entity] = result;
      visits.remove(entity);
    }
  }

  @override
  Future<ScanPage<GraphEntity>> readRedirectNeighbors(
    GraphEntity entity, {
    String? after,
    required int limit,
  }) async {
    _read();
    final sorted = (neighbors[entity] ?? {}).toList()
      ..sort((a, b) => entityKey(a).compareTo(entityKey(b)));
    return _page(sorted, entityKey, after, limit);
  }

  @override
  Future<void> enqueueAnomaly(
    GraphEntity entity,
    GraphRelationStatus status,
  ) async {
    if (status != GraphRelationStatus.redirectCycle &&
        status != GraphRelationStatus.parallelRedirect) {
      throw StateError('Not anomaly');
    }
    final prior = anomalyMarks[entity];
    if (prior == GraphRelationStatus.redirectCycle || prior == status) return;
    anomalyMarks[entity] = status;
    relations[entity] = GraphRelation(status);
    anomalyQueue.addLast((entity, status));
  }

  @override
  Future<(GraphEntity, GraphRelationStatus)?> takeAnomaly() async =>
      anomalyQueue.isEmpty ? null : anomalyQueue.removeFirst();
}
