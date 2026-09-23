import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import '../contracts.dart';
import '../data/database.dart';
import '../domain/canonical.dart';
import '../domain/revision.dart';
import '../domain/quotation.dart';
import '../domain/values.dart';
import 'backup_format.dart' show validateBackupDecisionReceipt;

enum ImportDecisionAction { apply, skip, excludeError }

final class ImportDecisionDigest {
  const ImportDecisionDigest(this.decisionCount, this.resultCount, this.digest);
  final int decisionCount, resultCount;
  final String digest;
  bool get hasDecisions => decisionCount != 0;
}

final class ReceiptCursor {
  const ReceiptCursor({
    required this.version,
    required this.sourceFingerprint,
    required this.eventId,
    required this.operationFingerprint,
  });
  final DatabaseVersion version;
  final String sourceFingerprint, eventId, operationFingerprint;
  int get fingerprintVersion => 1;
}

final class ReceiptResultCursor {
  const ReceiptResultCursor({
    required this.version,
    required this.sourceFingerprint,
    required this.eventId,
    required this.operationFingerprint,
    required this.revisionId,
  });
  final DatabaseVersion version;
  final String sourceFingerprint, eventId, operationFingerprint, revisionId;
  int get fingerprintVersion => 1;
}

final class SuccessfulImportOperation {
  const SuccessfulImportOperation({
    required this.eventId,
    required this.sourceFingerprint,
    required this.operationFingerprint,
    required this.originalTargetId,
    required this.sourceCanonical,
    required this.operationCanonical,
  });
  final String eventId,
      sourceFingerprint,
      operationFingerprint,
      originalTargetId;
  final String? sourceCanonical, operationCanonical;
  bool get legacyDetailsUnknown => operationCanonical == null;
}

final class ImportReceiptPage {
  ImportReceiptPage(List<SuccessfulImportOperation> items, this.nextCursor)
    : items = List.unmodifiable(items);
  final List<SuccessfulImportOperation> items;
  final ReceiptCursor? nextCursor;
}

final class ImportReceiptResultPage {
  ImportReceiptResultPage(List<String> revisionIds, this.nextCursor)
    : revisionIds = List.unmodifiable(revisionIds);
  final List<String> revisionIds;
  final ReceiptResultCursor? nextCursor;
}

/// Storage primitives only: callers bind the active installation/version before
/// matching or sealing. This helper never chooses entities, aliases, IDs or time.
final class ImportReceiptStore {
  ImportReceiptStore(this.database);
  final SupplierDatabase database;
  static const _pageSize = 32;
  static const _rowBudget = 512 * 1024;

  Future<ImportReceiptPage> readSourceReceipts(
    SourceFingerprint source, {
    ReceiptCursor? after,
    int limit = 50,
  }) => database.transaction(() async {
    _limit(limit);
    final version = await database.currentVersion();
    if (after != null &&
        (!sameVersion(after.version, version) ||
            after.sourceFingerprint != source.digest)) {
      _fail(
        'Receipt cursor is stale or belongs to another source',
        'STALE_CURSOR',
      );
    }
    final detailed = database.storageVersion >= 3;
    final rows = await database.rows(
      '''SELECT r.event_id,r.operation_fingerprint,MIN(r.original_target_id) original_target_id,COUNT(DISTINCT r.original_target_id) target_count,
${detailed ? 'd.source_canonical,d.operation_canonical' : 'NULL source_canonical,NULL operation_canonical'}
FROM import_row_receipt r JOIN commit_receipt c ON c.event_id=r.event_id
${detailed ? 'LEFT JOIN import_decision_receipt d ON d.event_id=r.event_id AND d.source_fingerprint=r.source_fingerprint AND d.operation_fingerprint=r.operation_fingerprint' : ''}
WHERE r.fingerprint_version=1 AND r.source_fingerprint=? ${after == null ? '' : 'AND (r.event_id,r.operation_fingerprint)>(?,?)'}
GROUP BY r.event_id,r.operation_fingerprint ORDER BY r.event_id,r.operation_fingerprint LIMIT ?''',
      [
        Variable(source.digest),
        if (after != null) ...[
          Variable(after.eventId),
          Variable(after.operationFingerprint),
        ],
        Variable(limit + 1),
      ],
    );
    final items = <SuccessfulImportOperation>[];
    for (final row in rows.take(limit)) {
      if (row.read<int>('target_count') != 1) {
        _fail('Receipt operation has inconsistent original targets');
      }
      final sourceCanonical = row.readNullable<String>('source_canonical'),
          operationCanonical = row.readNullable<String>('operation_canonical');
      if ((sourceCanonical == null) != (operationCanonical == null) ||
          sourceCanonical != null && sourceCanonical != source.canonical) {
        _fail('Receipt source canonical differs');
      }
      items.add(
        SuccessfulImportOperation(
          eventId: row.read<String>('event_id'),
          sourceFingerprint: source.digest,
          operationFingerprint: row.read<String>('operation_fingerprint'),
          originalTargetId: row.read<String>('original_target_id'),
          sourceCanonical: sourceCanonical,
          operationCanonical: operationCanonical,
        ),
      );
    }
    final last = items.isEmpty ? null : items.last;
    return ImportReceiptPage(
      items,
      rows.length > limit
          ? ReceiptCursor(
              version: version,
              sourceFingerprint: source.digest,
              eventId: last!.eventId,
              operationFingerprint: last.operationFingerprint,
            )
          : null,
    );
  });

  Future<ImportReceiptResultPage> readReceiptResults({
    required String eventId,
    required SourceFingerprint source,
    required String operationFingerprint,
    ReceiptResultCursor? after,
    int limit = 50,
  }) => database.transaction(() async {
    _limit(limit);
    _identity(eventId);
    _fingerprint(operationFingerprint);
    final version = await database.currentVersion();
    if (after != null &&
        (!sameVersion(after.version, version) ||
            after.sourceFingerprint != source.digest ||
            after.eventId != eventId ||
            after.operationFingerprint != operationFingerprint)) {
      _fail(
        'Result cursor is stale or belongs to another operation',
        'STALE_CURSOR',
      );
    }
    final rows = await database.rows(
      '''SELECT r.result_revision_id FROM import_row_receipt r JOIN commit_receipt c ON c.event_id=r.event_id
WHERE r.event_id=? AND r.fingerprint_version=1 AND r.source_fingerprint=? AND r.operation_fingerprint=? ${after == null ? '' : 'AND r.result_revision_id>?'} ORDER BY r.result_revision_id LIMIT ?''',
      [
        Variable(eventId),
        Variable(source.digest),
        Variable(operationFingerprint),
        if (after != null) Variable(after.revisionId),
        Variable(limit + 1),
      ],
    );
    final ids = rows
        .take(limit)
        .map((r) => r.read<String>('result_revision_id'))
        .toList();
    return ImportReceiptResultPage(
      ids,
      rows.length > limit
          ? ReceiptResultCursor(
              version: version,
              sourceFingerprint: source.digest,
              eventId: eventId,
              operationFingerprint: operationFingerprint,
              revisionId: ids.last,
            )
          : null,
    );
  });

  /// Atomic single-decision staging. Results are consumed one at a time; no
  /// arbitrary quantity cap or whole-result collection is introduced.
  Future<void> stageDecision({
    required String jobId,
    required String decisionId,
    required ImportDecisionAction action,
    SourceFingerprint? source,
    OperationFingerprint? operation,
    required String originalTargetId,
    required Map<String, Object?> confirmationDetails,
    String? exclusionReason,
    Iterable<String> resultRevisionIds = const [],
  }) => database.transaction(() async {
    _identity(jobId);
    _identity(decisionId);
    final canonical = canonicalJson({
      'version': 1,
      'action': action.name,
      'source_fingerprint': source?.digest,
      'operation_fingerprint': operation?.digest,
      'original_target_id': originalTargetId,
      'confirmation_details': confirmationDetails,
      'exclusion_reason': exclusionReason,
    });
    _budget([source?.canonical, operation?.canonical, canonical]);
    final row = <String, Object?>{
      'job_id': jobId,
      'decision_id': decisionId,
      'action': action.name,
      'fingerprint_version': 1,
      'source_fingerprint': source?.digest,
      'source_canonical': source?.canonical,
      'operation_fingerprint': operation?.digest,
      'operation_canonical': operation?.canonical,
      'original_target_id': originalTargetId,
      'decision_canonical': canonical,
      'exclusion_reason': exclusionReason,
    };
    _validateDecision(row);
    await database.customStatement(
      'INSERT INTO staging_import_decision(${row.keys.join(',')}) VALUES(${List.filled(row.length, '?').join(',')})',
      row.values.toList(),
    );
    for (final revisionId in resultRevisionIds) {
      _fingerprint(revisionId);
      await database.customStatement(
        'INSERT INTO staging_import_result VALUES(?,?,?)',
        [jobId, decisionId, revisionId],
      );
    }
    await _validateResults(row);
    await _validateUniqueMainResults(jobId);
  });

  /// Includes skip/exclusions and explicit acknowledgements. The domain marker,
  /// ordered canonical rows and ordered allocations prevent boundary ambiguity.
  Future<String> computeDecisionDigest(String jobId) async =>
      (await inspectDecisionDigest(jobId)).digest;

  Future<ImportDecisionDigest> inspectDecisionDigest(
    String jobId,
  ) => database.transaction(() async {
    final output = _DigestSink();
    final sink = sha256.startChunkedConversion(output);
    sink.add(utf8.encode('supplier-import-decisions-v1\n'));
    var decisions = 0, results = 0;
    await for (final row in _decisions(jobId)) {
      decisions++;
      sink.add(utf8.encode('${canonicalJson(['decision', row])}\n'));
      await for (final result in _results(
        jobId,
        row['decision_id']! as String,
      )) {
        results++;
        sink.add(
          utf8.encode(
            '${canonicalJson(['result', row['decision_id'], result['result_revision_id']])}\n',
          ),
        );
      }
    }
    sink.close();
    return ImportDecisionDigest(decisions, results, output.value.toString());
  });

  Future<void> validateStaged(String jobId) => database.transaction(() async {
    await _validateCoverage(jobId);
    await _validateUniqueMainResults(jobId);
    await for (final row in _decisions(jobId)) {
      _validateDecision(row);
      await _validateResults(row);
    }
  });

  /// INTERNAL COMMIT PRIMITIVE. Caller must invoke inside its already-held
  /// application lock AND existing SQL transaction, after receipt_result has
  /// been inserted. Drift exposes no stable public transaction-state getter.
  /// This method does not open/commit a transaction. Any failure must roll back
  /// the caller's whole transaction; callers must not catch and commit it.
  Future<void> copyAppliedToReceipt(String jobId, String eventId) async {
    await _validateCoverage(jobId, authorityInstalled: true);
    await _validateUniqueMainResults(jobId);
    final event = await database.rows(
      'SELECT job_id FROM confirmation_event WHERE event_id=?',
      [Variable(eventId)],
    );
    if (event.length != 1 || event.single.data['job_id'] != jobId) {
      _fail('Confirmation does not belong to staged job');
    }
    await for (final row in _decisions(jobId)) {
      _validateDecision(row);
      await _validateResults(row, authorityInstalled: true);
      if (row['action'] != 'apply') {
        continue;
      }
      final decisionId = row['decision_id']! as String;
      if ((await database.rows(
        '''SELECT 1 FROM staging_import_result s WHERE s.job_id=? AND s.decision_id=? AND NOT EXISTS(SELECT 1 FROM receipt_result r WHERE r.event_id=? AND r.revision_id=s.result_revision_id) LIMIT 1''',
        [Variable(jobId), Variable(decisionId), Variable(eventId)],
      )).isNotEmpty) {
        _fail('Main result is absent from confirmation result set');
      }
      await database.customStatement(
        'INSERT INTO import_decision_receipt VALUES(?,?,?,?,?,?,?)',
        [
          eventId,
          1,
          row['source_fingerprint'],
          row['operation_fingerprint'],
          row['source_canonical'],
          row['operation_canonical'],
          row['original_target_id'],
        ],
      );
      await for (final result in _results(jobId, decisionId)) {
        await database.customStatement(
          'INSERT INTO import_row_receipt VALUES(?,?,?,?,?,?)',
          [
            eventId,
            1,
            row['source_fingerprint'],
            row['operation_fingerprint'],
            row['original_target_id'],
            result['result_revision_id'],
          ],
        );
      }
    }
  }

  Stream<Map<String, Object?>> _decisions(String jobId) async* {
    // Synthetic jobs in retained physical-v2 stores have no decision table.
    if (database.storageVersion < 3) {
      return;
    }
    _identity(jobId);
    if ((await database.rows(
      'SELECT 1 FROM staging_import_decision WHERE job_id=? AND COALESCE(octet_length(source_canonical),0)+COALESCE(octet_length(operation_canonical),0)+octet_length(decision_canonical)>? LIMIT 1',
      [Variable(jobId), Variable(_rowBudget)],
    )).isNotEmpty) {
      _fail('Decision row exceeds budget');
    }
    String? after;
    while (true) {
      final rows = await database.rows(
        'SELECT * FROM staging_import_decision WHERE job_id=? ${after == null ? '' : 'AND decision_id>?'} ORDER BY decision_id LIMIT $_pageSize',
        [Variable(jobId), if (after != null) Variable(after)],
      );
      if (rows.isEmpty) {
        break;
      }
      for (final row in rows) {
        yield row.data;
      }
      after = rows.last.read<String>('decision_id');
    }
  }

  Stream<Map<String, Object?>> _results(
    String jobId,
    String decisionId,
  ) async* {
    String? after;
    while (true) {
      final rows = await database.rows(
        'SELECT result_revision_id FROM staging_import_result WHERE job_id=? AND decision_id=? ${after == null ? '' : 'AND result_revision_id>?'} ORDER BY result_revision_id LIMIT $_pageSize',
        [
          Variable(jobId),
          Variable(decisionId),
          if (after != null) Variable(after),
        ],
      );
      if (rows.isEmpty) {
        break;
      }
      for (final row in rows) {
        yield row.data;
      }
      after = rows.last.read<String>('result_revision_id');
    }
  }

  Future<void> _validateCoverage(
    String jobId, {
    bool authorityInstalled = false,
  }) async {
    if (database.storageVersion < 3 ||
        (await database.rows(
          'SELECT 1 FROM staging_import_decision WHERE job_id=? LIMIT 1',
          [Variable(jobId)],
        )).isEmpty) {
      return;
    }
    final uncovered = await database.rows(
      """SELECT 1 FROM staging_revision r WHERE r.job_id=? AND (
      (json_extract(r.canonical,'\$.entity_type')='quotation' AND NOT EXISTS(
        SELECT 1 FROM staging_import_result s JOIN staging_import_decision d ON d.job_id=s.job_id AND d.decision_id=s.decision_id WHERE s.job_id=r.job_id AND s.result_revision_id=r.revision_id AND d.action='apply'))
      OR (json_extract(r.canonical,'\$.entity_type')<>'quotation' AND (
        json_extract(r.canonical,'\$.kind')<>'put' OR json_array_length(r.canonical,'\$.parents')<>0 OR NOT EXISTS(
          SELECT 1 FROM staging_import_result s JOIN staging_import_decision d ON d.job_id=s.job_id AND d.decision_id=s.decision_id JOIN staging_revision q ON q.job_id=s.job_id AND q.revision_id=s.result_revision_id
          WHERE s.job_id=r.job_id AND d.action='apply' AND json_extract(r.canonical,'\$.entity_id')=CASE json_extract(r.canonical,'\$.entity_type') WHEN 'supplier' THEN json_extract(q.canonical,'\$.payload.supplier_id') WHEN 'product' THEN json_extract(q.canonical,'\$.payload.product_id') WHEN 'contact' THEN json_extract(q.canonical,'\$.payload.contact_id') END
        )
      ))) LIMIT 1""",
      [Variable(jobId)],
    );
    if (!authorityInstalled &&
        (await database.rows(
          "SELECT 1 FROM staging_revision r JOIN entity_identity e ON e.entity_id=json_extract(r.canonical,'\$.entity_id') WHERE r.job_id=? AND json_extract(r.canonical,'\$.entity_type')<>'quotation' LIMIT 1",
          [Variable(jobId)],
        )).isNotEmpty) {
      _fail('Business inquiry import cannot edit existing auxiliary entities');
    }
    if (uncovered.isNotEmpty) {
      _fail(
        'Staged revisions include unselected quotation or unrelated auxiliary changes',
      );
    }
  }

  Future<void> _validateUniqueMainResults(String jobId) async {
    if (database.storageVersion < 3) {
      return;
    }
    final reused = await database.rows(
      "SELECT 1 FROM staging_import_result s JOIN staging_import_decision d ON d.job_id=s.job_id AND d.decision_id=s.decision_id JOIN staging_revision r ON r.job_id=s.job_id AND r.revision_id=s.result_revision_id WHERE s.job_id=? AND d.action='apply' GROUP BY json_extract(r.canonical,'\$.entity_id') HAVING COUNT(*)>1 LIMIT 1",
      [Variable(jobId)],
    );
    if (reused.isNotEmpty) {
      _fail('Main quotation cannot belong to multiple allocations');
    }
  }

  Future<void> _validateResults(
    Map<String, Object?> row, {
    bool authorityInstalled = false,
  }) async {
    final jobId = row['job_id']! as String,
        decisionId = row['decision_id']! as String;
    final count = (await database.rows(
      'SELECT COUNT(*) n FROM staging_import_result WHERE job_id=? AND decision_id=?',
      [Variable(jobId), Variable(decisionId)],
    )).single.read<int>('n');
    if (row['action'] != 'apply') {
      if (count != 0) {
        _fail('Non-apply decision has results');
      }
      return;
    }
    final operation =
        jsonDecode(row['operation_canonical']! as String)
            as Map<String, Object?>;
    if (count != operation['confirmed_quantity']) {
      _fail('Main result quantity differs from confirmation');
    }
    final distinct = (await database.rows(
      "SELECT COUNT(DISTINCT json_extract(r.canonical,'\$.entity_id')) n FROM staging_import_result s JOIN staging_revision r ON r.job_id=s.job_id AND r.revision_id=s.result_revision_id WHERE s.job_id=? AND s.decision_id=?",
      [Variable(jobId), Variable(decisionId)],
    )).single.read<int>('n');
    if (distinct != count) {
      _fail('Main results must be distinct entities in the same job');
    }
    await for (final result in _results(jobId, decisionId)) {
      final id = result['result_revision_id']! as String;
      final rows = await database.rows(
        'SELECT canonical FROM staging_revision WHERE job_id=? AND revision_id=? AND octet_length(canonical)<=?',
        [Variable(jobId), Variable(id), Variable(_rowBudget)],
      );
      if (rows.length != 1) {
        _fail('Main result is missing or oversized');
      }
      final revision = RevisionEnvelope.fromCanonicalJson(
        rows.single.read<String>('canonical'),
      );
      if (revision.revisionId != id ||
          revision.entityType != 'quotation' ||
          revision.kind != 'put') {
        _fail('Main result must be a canonical quotation put');
      }
      final exists = (await database.rows(
        "SELECT 1 FROM entity_identity WHERE entity_type='quotation' AND entity_id=?",
        [Variable(revision.entityId)],
      )).isNotEmpty;
      RevisionEnvelope? baseline;
      if (operation['intent'] == 'newInquiry' ||
          operation['intent'] == 'importHistorical') {
        final mode = operation['intent'] == 'importHistorical'
            ? 'historical'
            : 'standard';
        if (revision.parents.isNotEmpty ||
            revision.payload['capture_mode'] != mode ||
            (!authorityInstalled && exists)) {
          _fail(
            'Imported quotation requires a fresh root in its confirmed capture mode',
          );
        }
      } else {
        if (!exists ||
            revision.parents.length != 1 ||
            row['original_target_id'] != revision.entityId) {
          _fail(
            'Modify requires the original existing quotation target and nonempty parents',
          );
        }
        baseline = await database.findRevision(revision.parents.single);
        if (!authorityInstalled) {
          final current = await database.rows(
            "SELECT revision_id FROM entity_head WHERE entity_type='quotation' AND entity_id=? LIMIT 2",
            [Variable(revision.entityId)],
          );
          if (current.length != 1 ||
              current.single.data['revision_id'] != revision.parents.single) {
            _fail('Modify requires the unique current put head');
          }
        }
        final expected = (await database.rows(
          "SELECT 1 FROM staging_expected_entity WHERE job_id=? AND entity_type='quotation' AND entity_id=?",
          [Variable(jobId), Variable(revision.entityId)],
        )).isNotEmpty;
        final mismatch = await database.rows(
          "SELECT 1 WHERE (SELECT COUNT(*) FROM staging_expected_head WHERE job_id=? AND entity_type='quotation' AND entity_id=?)<>? OR EXISTS(SELECT revision_id FROM staging_expected_head WHERE job_id=? AND entity_type='quotation' AND entity_id=? EXCEPT SELECT value FROM json_each(?))",
          [
            Variable(jobId),
            Variable(revision.entityId),
            Variable(revision.parents.length),
            Variable(jobId),
            Variable(revision.entityId),
            Variable(jsonEncode(revision.parents)),
          ],
        );
        if (!expected || mismatch.isNotEmpty) {
          _fail(
            'Modify expected heads must equal all explicit revision parents',
          );
        }
      }
      validateImportResultPayload(
        revision,
        operation,
        originalTargetId: row['original_target_id']! as String,
        baseline: baseline,
      );
    }
  }
}

void _validateDecision(Map<String, Object?> row) {
  final decision = jsonDecode(row['decision_canonical']! as String);
  if (decision is! Map<String, Object?> ||
      canonicalJson(decision) != row['decision_canonical']) {
    _fail('Decision is not canonical');
  }
  exactKeys(decision, [
    'version',
    'action',
    'source_fingerprint',
    'operation_fingerprint',
    'original_target_id',
    'confirmation_details',
    'exclusion_reason',
  ]);
  for (final key in [
    'action',
    'source_fingerprint',
    'operation_fingerprint',
    'original_target_id',
    'exclusion_reason',
  ]) {
    if (decision[key] != row[key]) {
      _fail('Decision canonical differs from staged columns');
    }
  }
  if (decision['version'] != 1 ||
      row['fingerprint_version'] != 1 ||
      decision['confirmation_details'] is! Map<String, Object?>) {
    _fail('Unsupported decision structure');
  }
  final action = row['action'];
  if (!ImportDecisionAction.values.any((a) => a.name == action)) {
    _fail('Unknown decision action');
  }
  final source = row['source_canonical'],
      operation = row['operation_canonical'];
  if ((source == null) != (row['source_fingerprint'] == null) ||
      (operation == null) != (row['operation_fingerprint'] == null) ||
      action != 'excludeError' && source == null) {
    _fail('Incomplete source or operation');
  }
  if (action == 'excludeError' &&
      (row['exclusion_reason'] is! String ||
          (row['exclusion_reason']! as String).trim().isEmpty)) {
    _fail('Excluded error requires a reason');
  }
  if (action == 'apply') {
    if (operation == null) {
      _fail('Applied decision requires explicit operation');
    }
    validateBackupDecisionReceipt(row);
  } else {
    if (operation != null) {
      _fail('Skipped/excluded decision cannot carry an operation');
    }
    if (source != null) {
      // Reuse the strict source shape validator without inventing a persisted
      // operation for skipped/excluded rows. This sentinel exists only locally.
      final sentinel = canonicalJson({
        'version': 1,
        'source_fingerprint': row['source_fingerprint'],
        'intent': 'modify',
        'original_bindings': <String, Object?>{},
        'operations': <String, Object?>{},
        'confirmed_quantity': 1,
      });
      validateBackupDecisionReceipt({
        ...row,
        'operation_canonical': sentinel,
        'operation_fingerprint': canonicalSha256(jsonDecode(sentinel)),
      });
    }
  }
}

Never _fail(String message, [String code = 'INVALID_IMPORT_DECISION']) =>
    throw DomainFailure(code, message);
void _limit(int value) {
  if (value < 1 || value > 200) {
    throw RangeError.range(value, 1, 200, 'limit');
  }
}

void _identity(String value) {
  if (value.isEmpty || value.length > 200) {
    throw ArgumentError('Invalid durable identity');
  }
}

void _fingerprint(String value) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw ArgumentError('Invalid fingerprint');
  }
}

void _budget(List<String?> values) {
  var bytes = 0;
  for (final value in values) {
    if (value == null) {
      continue;
    }
    if (value.length > ImportReceiptStore._rowBudget) {
      _fail('Decision row exceeds budget');
    }
    bytes += utf8.encode(value).length;
  }
  if (bytes > ImportReceiptStore._rowBudget) {
    _fail('Decision row exceeds budget');
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest value) {
    this.value = value;
  }

  @override
  void close() {}
}

/// Pure intent/result consistency check shared by staging and logical restore.
/// It does not authorize a write or replace active-version/head CAS validation.
void validateImportResultPayload(
  RevisionEnvelope revision,
  Map<String, Object?> operation, {
  required String originalTargetId,
  RevisionEnvelope? baseline,
}) {
  if (revision.entityType != 'quotation' || revision.kind != 'put') {
    _fail('Import result must be quotation put');
  }
  final operations = operation['operations']! as Map<String, Object?>;
  if (operations.keys.any((field) => !Quotation.fields.contains(field))) {
    _fail('Unknown quotation operation field');
  }
  if (operation['intent'] == 'newInquiry' ||
      operation['intent'] == 'importHistorical') {
    final mode = operation['intent'] == 'importHistorical'
        ? 'historical'
        : 'standard';
    if (revision.parents.isNotEmpty ||
        revision.payload['capture_mode'] != mode ||
        operation['intent'] == 'importHistorical' &&
            originalTargetId.isNotEmpty) {
      _fail('Imported quotation requires a root in its confirmed capture mode');
    }
    if (operations.values.any(
      (cell) => (cell as Map<String, Object?>)['kind'] == 'keep',
    )) {
      _fail('New inquiry has no baseline for keep');
    }
  } else {
    if (baseline == null ||
        baseline.entityType != 'quotation' ||
        baseline.kind != 'put' ||
        baseline.entityId != revision.entityId ||
        originalTargetId != revision.entityId ||
        revision.parents.length != 1 ||
        revision.parents.single != baseline.revisionId) {
      _fail('Modify requires a unique original put baseline');
    }
  }
  for (final field in Quotation.fields) {
    final instruction = operations[field] as Map<String, Object?>?;
    final kind = instruction?['kind'];
    if (kind == 'set') {
      if (canonicalJson(revision.payload[field]) !=
          canonicalJson(instruction!['value'])) {
        _fail('Set operation differs from result payload');
      }
    } else if (kind == 'clear') {
      if (revision.payload[field] != null) {
        _fail('Clear operation differs from result payload');
      }
    } else if (operation['intent'] == 'modify') {
      if (canonicalJson(revision.payload[field]) !=
          canonicalJson(baseline!.payload[field])) {
        _fail('Undeclared or kept field changed');
      }
    }
  }
}
