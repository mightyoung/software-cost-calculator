import 'package:drift/drift.dart';
import '../contracts.dart';
import '../data/database.dart';
import '../data/commit_coordinator.dart';
import '../domain/entities.dart';
import '../domain/quotation.dart';
import '../domain/revision.dart';
import '../domain/canonical.dart';
import '../domain/values.dart';

/// Finite local edits share the same sealed union validator and atomic commit as
/// exchange. Only import/migration may create historical quotation roots.
class RecordService {
  RecordService(
    this.coordinator, {
    required this.deviceId,
    DateTime Function()? clock,
    String Function()? newId,
  }) : clock = clock ?? DateTime.now,
       newId = newId ?? _uuid;
  final CommitCoordinator coordinator;
  final String deviceId;
  final DateTime Function() clock;
  final String Function() newId;
  SupplierDatabase get database => coordinator.database;
  static String _uuid() {
    final raw = newStorageId().substring(0, 32);
    return '${raw.substring(0, 8)}-${raw.substring(8, 12)}-4${raw.substring(13, 16)}-8${raw.substring(17, 20)}-${raw.substring(20)}';
  }

  Future<String> createEntity(String type, Map<String, Object?> payload) async {
    if (!['supplier', 'contact', 'product'].contains(type)) {
      throw const DomainFailure(
        'dedicated_quotation_entry',
        'Use createQuotation for quotations',
      );
    }
    final id = newId();
    await _submit(
      () async => [
        _Edit(type, id, 'put', await _localPayload(type, payload), {}),
      ],
    );
    return id;
  }

  Future<String> createQuotation(Map<String, Object?> payload) async {
    final id = newId();
    await _submit(
      () async => [
        _Edit(
          'quotation',
          id,
          'put',
          await _localPayload('quotation', {
            ...payload,
            'capture_mode': 'standard',
          }),
          {},
        ),
      ],
    );
    return id;
  }

  Future<String> copyQuotation(
    String id,
    Map<String, Object?> overrides,
  ) async {
    final created = newId();
    await _submit(() async {
      final current = await _single('quotation', id);
      final payload = Quotation.fromJson(
        current.payload,
      ).copyAsNewInquiry(overrides).toJson();
      return [
        _Edit(
          'quotation',
          created,
          'put',
          await _localPayload('quotation', payload),
          {},
        ),
      ];
    });
    return created;
  }

  Future<String> correctEntity(
    String type,
    String id,
    Map<String, Object?> payload, {
    required Set<String> expectedHeads,
    bool allowExplicitClear = false,
  }) async {
    await _submit(() async {
      await _single(type, id);
      return [
        await _put(
          type,
          id,
          payload,
          expectedHeads,
          allowExplicitClear: allowExplicitClear,
        ),
      ];
    });
    return id;
  }

  Future<void> deleteEntity(
    String type,
    String id,
    Set<String> expectedHeads,
  ) => _submit(() async {
    await _requireKnown(type, id, expectedHeads);
    return [_Edit(type, id, 'delete', const {}, expectedHeads)];
  });
  Future<void> restoreEntity(
    String type,
    String id,
    Map<String, Object?> payload,
    Set<String> expectedHeads, {
    bool allowExplicitClear = false,
  }) => _submit(() async {
    final current = await _single(type, id, kind: 'delete');
    if (current.kind != 'delete') {
      throw const DomainFailure('not_deleted', 'Restore requires tombstone');
    }
    return [
      await _put(
        type,
        id,
        payload,
        expectedHeads,
        allowExplicitClear: allowExplicitClear,
      ),
    ];
  });
  Future<void> resolve(
    String type,
    String id,
    Map<String, Object?> completePayload,
    Set<String> expectedHeads, {
    bool allowExplicitClear = false,
  }) => _submit(
    () async => [
      await _put(
        type,
        id,
        completePayload,
        expectedHeads,
        allowExplicitClear: allowExplicitClear,
      ),
    ],
  );
  Future<void> mergeEntities(
    String type,
    String source,
    String target,
    Map<String, Object?> targetPayload,
    Map<String, Set<String>> expectedHeads,
  ) => _submit(() async {
    if (source == target) throw ArgumentError('Merge needs distinct entities');
    await _single(type, source);
    await _single(type, target);
    final sourceHeads = _expected(expectedHeads, source),
        targetHeads = _expected(expectedHeads, target);
    return [
      await _put(type, target, targetPayload, targetHeads),
      _Edit(type, source, 'redirect', {'target_id': target}, sourceHeads),
    ];
  });
  Future<void> repairAliases(
    String type,
    Set<String> ids,
    String keeper,
    Map<String, Object?> keeperPayload,
    Map<String, Set<String>> expectedHeads,
  ) => _submit(() async {
    if (ids.isEmpty || ids.length > 500 || !ids.contains(keeper)) {
      throw ArgumentError(
        'Repair requires bounded explicit set including keeper',
      );
    }
    final edits = <_Edit>[];
    for (final id in ids) {
      final heads = _expected(expectedHeads, id);
      await _requireKnown(type, id, heads);
      edits.add(
        id == keeper
            ? await _put(type, id, keeperPayload, heads)
            : _Edit(type, id, 'redirect', {'target_id': keeper}, heads),
      );
    }
    return edits;
  });
  Set<String> _expected(Map<String, Set<String>> all, String id) =>
      all[id] ??
      (throw const DomainFailure(
        'expected_heads_required',
        'Every affected entity requires expected heads',
      ));
  Future<_Edit> _put(
    String type,
    String id,
    Map<String, Object?> payload,
    Set<String> heads, {
    bool allowExplicitClear = false,
  }) async {
    await _requireKnown(type, id, heads);
    var normalized = validatePayload(type, payload);
    // Unchanged historical associations remain authority as captured. Only an
    // explicitly changed reference is resolved and checked against active data.
    for (final field in ['supplier_id', 'product_id']) {
      if (normalized[field] == null) continue;
      var changed = false;
      for (final parent in heads) {
        final before = await database.findRevision(parent);
        if (before == null ||
            before.entityId != id ||
            before.entityType != type) {
          throw const DomainFailure(
            'stale_heads',
            'Expected head belongs to another entity',
          );
        }
        if (before.kind != 'put' ||
            before.payload[field] != normalized[field]) {
          changed = true;
        }
      }
      if (changed) {
        normalized = {
          ...normalized,
          field: await _activeCanonical(
            field.substring(0, field.length - 3),
            normalized[field]! as String,
          ),
        };
      }
    }
    if (type == 'quotation') {
      final next = Quotation.fromJson(normalized);
      for (final parent in heads) {
        final previous = await database.findRevision(parent);
        if (previous == null ||
            previous.entityId != id ||
            previous.entityType != type) {
          throw const DomainFailure(
            'stale_heads',
            'Expected head belongs to another entity',
          );
        }
        if (previous.kind == 'put') {
          next.validateEditFrom(
            Quotation.fromJson(previous.payload),
            allowExplicitClear: allowExplicitClear,
          );
        }
      }
    }
    if (type == 'quotation' && normalized['contact_id'] != null) {
      var captureChanged = false;
      for (final head in heads) {
        final old = (await database.findRevision(head))!;
        if (old.kind != 'put' ||
            old.payload['contact_id'] != normalized['contact_id'] ||
            canonicalJson(old.payload['contact_snapshot']) !=
                canonicalJson(normalized['contact_snapshot']) ||
            old.payload['supplier_id'] != normalized['supplier_id']) {
          captureChanged = true;
        }
      }
      if (captureChanged) normalized = await _localPayload(type, normalized);
    }
    return _Edit(type, id, 'put', normalized, heads);
  }

  Future<void> _requireKnown(String type, String id, Set<String> heads) async {
    if (heads.isEmpty || heads.length > 500) {
      throw const DomainFailure(
        'expected_heads_required',
        'Existing entity requires bounded expected heads',
      );
    }
    if ((await database.rows(
      'SELECT 1 FROM entity_identity WHERE entity_type=? AND entity_id=?',
      [Variable(type), Variable(id)],
    )).isEmpty) {
      throw const DomainFailure('unknown_entity', 'Entity does not exist');
    }
  }

  Future<RevisionEnvelope> _single(
    String type,
    String id, {
    String kind = 'put',
  }) async {
    final rows = await database.rows(
      'SELECT r.canonical FROM entity_head h JOIN revision r ON r.revision_id=h.revision_id WHERE h.entity_type=? AND h.entity_id=? LIMIT 2',
      [Variable(type), Variable(id)],
    );
    if (rows.length != 1) {
      throw const DomainFailure(
        'entity_not_single',
        'Entity is missing or conflicted',
      );
    }
    final envelope = RevisionEnvelope.fromCanonicalJson(
      rows.single.read<String>('canonical'),
    );
    if (envelope.kind != kind) {
      throw const DomainFailure(
        'entity_state',
        'Use dedicated delete/restore/alias path',
      );
    }
    return envelope;
  }

  Future<String> _activeCanonical(String type, String id) async {
    final rows = await database.rows(
      'SELECT canonical_id,relation_status FROM alias_projection WHERE entity_type=? AND entity_id=?',
      [Variable(type), Variable(id)],
    );
    if (rows.length != 1 ||
        rows.single.read<String>('relation_status') != 'active' ||
        rows.single.readNullable<String>('canonical_id') == null) {
      throw const DomainFailure(
        'inactive_reference',
        'Reference is missing, deleted or conflicted',
      );
    }
    return rows.single.read<String>('canonical_id');
  }

  Future<Map<String, Object?>> _localPayload(
    String type,
    Map<String, Object?> raw,
  ) async {
    var payload = validatePayload(type, raw);
    for (final field in ['supplier_id', 'product_id']) {
      if (payload[field] != null) {
        payload = {
          ...payload,
          field: await _activeCanonical(
            field.substring(0, field.length - 3),
            payload[field]! as String,
          ),
        };
      }
    }
    if (type == 'quotation' && payload['contact_id'] != null) {
      final id = await _activeCanonical(
        'contact',
        payload['contact_id']! as String,
      );
      final contact = await _single('contact', id);
      final contactPayload = {
        ...contact.payload,
        'supplier_id': await _activeCanonical(
          'supplier',
          contact.payload['supplier_id']! as String,
        ),
      };
      payload = {...payload, 'contact_id': id};
      Quotation.fromJson(
        payload,
      ).validateContact(id, Contact.fromJson(contactPayload));
    }
    return payload;
  }

  Future<void> _submit(Future<List<_Edit>> Function() build) async {
    late PreviewToken token;
    late String event;
    await coordinator.writeLock.run(() async {
      final active = await coordinator.readActiveVersion();
      final current = await database.currentVersion();
      if (active.instanceId != current.instanceId ||
          active.activeEpoch != current.activeEpoch) {
        throw const DomainFailure(
          'stale_active_database',
          'Connection inactive',
        );
      }
      await database.transaction(() async {
        final edits = await build();
        final job = newStorageId();
        event = newStorageId();
        await database.createJob(job);
        for (final edit in edits) {
          requireUuid(edit.id, 'entity_id');
          final envelope = RevisionEnvelope.create(
            entityType: edit.type,
            entityId: edit.id,
            parents: edit.heads.toList(),
            kind: edit.kind,
            payload: edit.payload,
            authoredAt: normalizeInstant(
              DateTime.fromMillisecondsSinceEpoch(
                clock().millisecondsSinceEpoch,
                isUtc: true,
              ).toIso8601String(),
            ),
            originDeviceId: deviceId,
          );
          await database.appendStaging(job, envelope);
          await database.customStatement(
            'INSERT INTO staging_expected_entity VALUES(?,?,?)',
            [job, edit.type, edit.id],
          );
          for (final head in edit.heads) {
            await database.customStatement(
              'INSERT INTO staging_expected_head VALUES(?,?,?,?)',
              [job, edit.type, edit.id, head],
            );
          }
        }
        token = await database.sealJob(
          job,
          canonicalSha256(
            edits
                .map(
                  (e) => {
                    'type': e.type,
                    'id': e.id,
                    'heads': e.heads.toList()..sort(),
                  },
                )
                .toList(),
          ),
        );
        await database.registerConfirmation(event, token);
      });
    });
    try {
      await coordinator.commitStaged(
        jobId: token.jobId,
        expectedPreviewToken: token,
        confirmationEventId: event,
      );
    } catch (error) {
      // Cleanup failures carry both causes and any committed receipt. Preserve
      // that diagnostic even when business data has already committed.
      if (error is DomainFailure && error.code == 'graph_cleanup_failed') {
        rethrow;
      }
      // A response failure after COMMIT is resolved against the same persisted
      // event, never by inventing another local inquiry.
      if (await coordinator.findCommittedEvent(event) == null) rethrow;
    }
  }
}

class _Edit {
  _Edit(this.type, this.id, this.kind, this.payload, Set<String> heads)
    : heads = Set.unmodifiable(heads);
  final String type, id, kind;
  final Map<String, Object?> payload;
  final Set<String> heads;
}
