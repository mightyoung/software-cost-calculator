import 'dart:convert';
import 'package:drift/drift.dart';
import '../contracts.dart';
import '../data/database.dart';
import '../data/commit_coordinator.dart' show newStorageId;
import '../domain/canonical.dart';
import '../domain/quotation.dart';
import '../domain/revision.dart';
import '../domain/values.dart';
import '../exchange/business_import.dart';
import '../exchange/business_mapping.dart';
import '../exchange/business_preview.dart';
import '../exchange/import_receipts.dart';
import '../exchange/xlsx_staging.dart';
import '../query/candidates.dart';
import 'exchange_service.dart';

enum BusinessRowChoice {
  modify,
  newInquiry,
  importHistorical,
  skip,
  excludeError,
}

/// Explicit choices, not trusted revision envelopes. Blank/missing inputs keep
/// existing fields on modify. Only clearFields may remove existing information.
final class BusinessRowDecision {
  const BusinessRowDecision({
    required this.choice,
    this.targetId,
    this.bindings = const {},
    this.setFields = const {},
    this.clearFields = const {},
    this.keepFields = const {},
    this.createSupplier,
    this.createProduct,
    this.quantity = 1,
    this.acknowledgeConversions = false,
    this.reprocessSuccessfulSource = false,
    this.exclusionReason,
  });
  final BusinessRowChoice choice;
  final String? targetId, exclusionReason;
  final Map<String, String> bindings;
  final Map<String, Object?> setFields;
  final Map<String, Object?>? createSupplier, createProduct;
  final Set<String> clearFields;
  final Set<String> keepFields;
  final int quantity;
  final bool acknowledgeConversions, reprocessSuccessfulSource;
}

final class BusinessRowPreview {
  const BusinessRowPreview(
    this.mapped,
    this.previous,
    this.candidates,
    this.targetState,
    this.current,
    this.exportBaseline,
  );
  final BusinessMappedRow mapped;
  final ImportReceiptPage? previous;
  final Map<String, List<Candidate>> candidates;
  final String targetState;
  final RevisionEnvelope? current, exportBaseline;
  bool get alreadyImported => previous?.items.isNotEmpty ?? false;
}

final class BusinessImportSummary {
  const BusinessImportSummary(
    this.applied,
    this.skipped,
    this.excluded,
    this.results, {
    this.modified = 0,
    this.newInquiries = 0,
    this.historical = 0,
  });
  final int applied, skipped, excluded, results;
  final int modified, newInquiries, historical;
}

/// Converts an actual parsed workbook to durable user decisions. Allocation,
/// baselines, payload normalization and row coverage live in the service layer.
/// Reopen with the same job/staging/mapping; decisions already persisted remain.
final class BusinessImportWorkflow {
  BusinessImportWorkflow({
    required this.exchange,
    required this.jobId,
    required this.staging,
    required this.mapping,
    required this.deviceId,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now {
    requireUuid(deviceId, 'device_id');
  }
  final ExchangeService exchange;
  final String jobId, deviceId;
  final XlsxStaging staging;
  final BusinessMapping mapping;
  final DateTime Function() clock;
  SupplierDatabase get _db => exchange.coordinator.database;

  Future<Map<String, Object?>?> decisionForRow(int row) async {
    final rows = await _db.rows(
      'SELECT decision_canonical,operation_canonical FROM staging_import_decision WHERE job_id=? AND decision_id=?',
      [Variable(jobId), Variable('row:$row')],
    );
    if (rows.isEmpty) return null;
    return Map.unmodifiable({
      ...jsonDecode(rows.single.read<String>('decision_canonical'))
          as Map<String, Object?>,
      'operation':
          rows.single.readNullable<String>('operation_canonical') == null
          ? null
          : jsonDecode(rows.single.read<String>('operation_canonical')),
    });
  }

  Future<List<BusinessRowPreview>> previewPage({
    int? afterRow,
    int limit = 20,
  }) async {
    RangeError.checkValueInInterval(limit, 1, 50, 'limit');
    final rows = await exchange.previewRows(
      jobId,
      staging,
      afterRow: afterRow ?? mapping.headerRow,
      limit: limit,
    );
    return [for (final row in rows) await previewRow(row.row)];
  }

  Future<BusinessRowPreview> previewRow(int row) async {
    if (row <= mapping.headerRow) {
      throw ArgumentError('Header is not an import row');
    }
    final exists = await exchange.previewRows(
      jobId,
      staging,
      afterRow: row - 1,
      limit: 1,
    );
    if (exists.isEmpty || exists.single.row != row) {
      throw ArgumentError('Unknown row');
    }
    final cells = <int, RawBusinessCell>{};
    var cursor = 0;
    while (true) {
      final page = await exchange.previewCells(
        jobId,
        staging,
        row,
        afterColumn: cursor,
      );
      if (page.isEmpty) break;
      for (final item in page) {
        if (mapping.columns.values.any((c) => c.column == item.column)) {
          cells[item.column] = item.cell;
        }
      }
      cursor = page.last.column;
    }
    final profile = await staging.profile();
    final mapped = mapping.convert(
      row,
      cells,
      date1904: profile['date1904']! as bool,
    );
    if (mapped.source == null) {
      return BusinessRowPreview(mapped, null, const {}, 'invalid', null, null);
    }
    final found = await exchange.sourceFirst(jobId, mapped.source!, () async {
      final candidates = <String, List<Candidate>>{};
      for (final type in ['supplier', 'product']) {
        final name = mapped.values['${type}_name'];
        if (name is String && name.isNotEmpty) {
          candidates[type] = await CandidateRepository(
            _db,
          ).find(type, {'name': name}, limit: 20);
        }
      }
      return candidates;
    });
    RevisionEnvelope? current, baseline;
    var state = 'unbound';
    final incomingId = mapped.values['record_id'];
    if (incomingId is String) {
      final heads = await _heads('quotation', incomingId);
      state = heads.isEmpty
          ? 'unknown'
          : heads.length > 1
          ? 'conflicted'
          : heads.single.kind;
      if (heads.length == 1) current = heads.single;
      final exported = mapped.values['export_revision_id'];
      if (exported is String) {
        final revision = await _db.findRevision(exported);
        if (revision?.entityType == 'quotation' &&
            revision?.entityId == incomingId &&
            revision?.kind == 'put') {
          baseline = revision;
        }
      }
    }
    return BusinessRowPreview(
      mapped,
      found.receipts,
      Map.unmodifiable(found.candidates ?? {}),
      state,
      current,
      baseline,
    );
  }

  Future<List<RevisionEnvelope>> _heads(String type, String id) async => [
    for (final row in await _db.rows(
      'SELECT r.canonical FROM entity_head h JOIN revision r ON r.revision_id=h.revision_id WHERE h.entity_type=? AND h.entity_id=? LIMIT 2',
      [Variable(type), Variable(id)],
    ))
      RevisionEnvelope.fromCanonicalJson(row.read<String>('canonical')),
  ];

  Future<RevisionEnvelope> _active(String type, String id) async {
    requireUuid(id, '${type}_id');
    final heads = await _heads(type, id);
    if (heads.length != 1 || heads.single.kind != 'put') {
      throw const DomainFailure(
        'import_target_state',
        'Choose an existing active single-head record; deleted, redirected and conflicted records require their dedicated flow',
      );
    }
    return heads.single;
  }

  Future<void> decide(int row, BusinessRowDecision decision) async {
    final preview = await previewRow(row), mapped = preview.mapped;
    if (decision.choice != BusinessRowChoice.excludeError &&
        mapped.issues.isNotEmpty) {
      throw const DomainFailure(
        'import_row_invalid',
        'Fix the row or explicitly exclude it with a reason',
      );
    }
    final details = <String, Object?>{
      'rows': [row],
      'mapping': mapping.configuration,
      'conversions': [
        for (final conversion in mapped.conversions) conversion.toJson(),
      ],
      'conversion_acknowledged': decision.acknowledgeConversions,
      'reprocess_successful_source': decision.reprocessSuccessfulSource,
      'errors': [
        for (final issue in mapped.issues)
          {
            'field': issue.field,
            'coordinate': issue.coordinate,
            'message': issue.message,
          },
      ],
    };
    final id = 'row:$row';
    if (decision.choice == BusinessRowChoice.excludeError ||
        decision.choice == BusinessRowChoice.skip) {
      if (decision.choice == BusinessRowChoice.excludeError &&
          mapped.issues.isEmpty) {
        // Payload validation may fail only after explicit bindings/operations;
        // the caller must still supply its visible reason through this choice.
        if (decision.exclusionReason?.trim().isNotEmpty != true) {
          throw ArgumentError('Exclusion reason required');
        }
      }
      await exchange.stageDecision(
        jobId,
        BusinessImportDecision(
          id: id,
          action: decision.choice == BusinessRowChoice.skip
              ? ImportDecisionAction.skip
              : ImportDecisionAction.excludeError,
          source: mapped.source,
          originalTargetId: decision.targetId ?? '',
          confirmationDetails: details,
          exclusionReason: decision.exclusionReason,
        ),
      );
      return;
    }
    if (mapped.conversions.isNotEmpty && !decision.acknowledgeConversions) {
      throw const DomainFailure(
        'import_conversion_confirmation',
        'Review and acknowledge format conversions before applying',
      );
    }
    if (preview.alreadyImported && !decision.reprocessSuccessfulSource) {
      throw const DomainFailure(
        'import_already_processed',
        'Previously imported: skip, or explicitly confirm a new processing decision',
      );
    }
    if (decision.quantity < 1 ||
        decision.quantity > 1000 ||
        decision.choice == BusinessRowChoice.modify && decision.quantity != 1 ||
        decision.setFields.keys.any((key) => !Quotation.fields.contains(key)) ||
        decision.clearFields.any((key) => !Quotation.fields.contains(key)) ||
        decision.keepFields.any((key) => !Quotation.fields.contains(key)) ||
        decision.keepFields.any(
          (key) =>
              decision.clearFields.contains(key) ||
              decision.setFields.containsKey(key),
        ) ||
        decision.setFields.keys.any(decision.clearFields.contains) ||
        decision.bindings.keys.any(
          (key) => !['supplier_id', 'product_id', 'contact_id'].contains(key),
        )) {
      throw ArgumentError('Invalid explicit row operation');
    }
    final modifying = decision.choice == BusinessRowChoice.modify;
    final historical = decision.choice == BusinessRowChoice.importHistorical;
    if (historical &&
        (mapping.captureMode != CaptureMode.historical ||
            decision.targetId != null)) {
      throw const DomainFailure(
        'import_historical_mode',
        'Historical import requires the explicit historical entry and no existing target',
      );
    }
    final baseline = modifying
        ? await _active('quotation', decision.targetId ?? '')
        : null;
    final auxiliary = <RevisionEnvelope>[];
    final selectedBindings = Map<String, String>.from(decision.bindings);
    for (final entry in {
      'supplier': decision.createSupplier,
      'product': decision.createProduct,
    }.entries) {
      if (entry.value == null) continue;
      final key = '${entry.key}_id';
      if (selectedBindings.containsKey(key) ||
          decision.setFields.containsKey(key)) {
        throw ArgumentError(
          'Choose an existing $key or explicitly create one, not both',
        );
      }
      final entity = RevisionEnvelope.create(
        entityType: entry.key,
        entityId: _uuid(),
        parents: [],
        kind: 'put',
        payload: entry.value!,
        authoredAt: _timestamp(),
        originDeviceId: deviceId,
      );
      auxiliary.add(entity);
      selectedBindings[key] = entity.entityId;
    }
    final payload = <String, Object?>{
      for (final key in Quotation.fields) key: null,
      if (!modifying) ...{
        'currency': 'CNY',
        'tax_mode': 'unknown',
        'min_qty': '1',
        'inquiry_precision': 'unknown',
        'capture_mode': historical ? 'historical' : 'standard',
      },
      if (baseline != null) ...baseline.payload,
    };
    final operations = <String, FieldOperation>{};
    final incoming = <String, Object?>{
      ...mapping.defaults,
      for (final key in Quotation.fields)
        if (mapped.values.containsKey(key) &&
            ![
              'supplier_id',
              'product_id',
              'contact_id',
              'capture_mode',
            ].contains(key))
          key: mapped.values[key],
      if (mapped.values['inquiry_time'] is Map)
        ...(mapped.values['inquiry_time']! as Map).cast<String, Object?>(),
      ...decision.setFields,
      ...selectedBindings,
    };
    if (!modifying && decision.keepFields.isNotEmpty) {
      throw const DomainFailure(
        'import_new_keep',
        'New records have no baseline for keep',
      );
    }
    for (final field in decision.keepFields) {
      incoming.remove(field);
      operations[field] = const FieldOperation.keep();
    }
    for (final entry in incoming.entries) {
      if (entry.value == null) {
        if (mapped.values['inquiry_time'] is Map &&
            (mapped.values['inquiry_time']! as Map).containsKey(entry.key) &&
            !decision.setFields.containsKey(entry.key)) {
          payload[entry.key] = null;
          operations[entry.key] = const FieldOperation.clear();
          continue;
        }
        throw ArgumentError('Use clearFields for explicit clearing');
      }
      payload[entry.key] = entry.value;
      operations[entry.key] = FieldOperation.set(entry.value!);
    }
    for (final key in decision.clearFields) {
      payload[key] = null;
      operations[key] = const FieldOperation.clear();
    }
    if (!modifying) {
      payload['capture_mode'] = historical ? 'historical' : 'standard';
    }
    if (selectedBindings['contact_id'] != null) {
      final contact = await _active('contact', selectedBindings['contact_id']!);
      final snapshot = <String, Object?>{
        for (final field in ['name', 'phone', 'wechat', 'email'])
          field: contact.payload[field],
      };
      payload['contact_snapshot'] = snapshot;
      operations['contact_snapshot'] = FieldOperation.set(snapshot);
    }
    final normalized = Quotation.fromJson(payload);
    if (baseline != null) {
      normalized.validateEditFrom(
        Quotation.fromJson(baseline.payload),
        allowExplicitClear: true,
      );
    }
    final resultPayload = normalized.toJson();
    for (final key in operations.keys.toList()) {
      if (operations[key]!.kind == FieldOperationKind.set) {
        operations[key] = FieldOperation.set(resultPayload[key]!);
      }
    }
    for (final type in ['supplier', 'product']) {
      if (!auxiliary.any(
        (r) =>
            r.entityType == type && r.entityId == resultPayload['${type}_id'],
      )) {
        await _active(type, resultPayload['${type}_id']! as String);
      }
    }
    if (resultPayload['contact_id'] != null) {
      final contact = await _active(
        'contact',
        resultPayload['contact_id']! as String,
      );
      if (contact.payload['supplier_id'] != resultPayload['supplier_id']) {
        throw const DomainFailure(
          'import_contact_owner',
          'Selected contact belongs to another supplier',
        );
      }
    }
    final revisions = <RevisionEnvelope>[];
    for (var i = 0; i < decision.quantity; i++) {
      revisions.add(
        RevisionEnvelope.create(
          entityType: 'quotation',
          entityId: baseline?.entityId ?? _uuid(),
          parents: baseline == null ? [] : [baseline.revisionId],
          kind: 'put',
          payload: resultPayload,
          authoredAt: _timestamp(),
          originDeviceId: deviceId,
        ),
      );
    }
    final operation = OperationFingerprint.create(
      source: mapped.source!,
      intent: modifying
          ? ImportIntent.modify
          : historical
          ? ImportIntent.importHistorical
          : ImportIntent.newInquiry,
      originalBindings: {
        if (decision.targetId != null) 'quotation_id': decision.targetId,
        ...selectedBindings,
      },
      operations: operations,
      confirmedQuantity: decision.quantity,
    );
    await exchange.stageDecision(
      jobId,
      BusinessImportDecision(
        id: id,
        action: ImportDecisionAction.apply,
        source: mapped.source,
        operation: operation,
        originalTargetId: decision.targetId ?? '',
        confirmationDetails: details,
        revisions: [...auxiliary, ...revisions],
        resultRevisionIds: revisions.map((r) => r.revisionId),
      ),
    );
  }

  /// Every real data row must have an explicit durable decision. No caller can
  /// seal just its visible page and silently drop unvisited or erroneous rows.
  Future<BusinessImportSummary> summary() async {
    var modified = 0, newInquiries = 0, historical = 0;
    var cursor = mapping.headerRow,
        applied = 0,
        skipped = 0,
        excluded = 0,
        results = 0;
    while (true) {
      final page = await exchange.previewRows(
        jobId,
        staging,
        afterRow: cursor,
        limit: 100,
      );
      if (page.isEmpty) break;
      for (final row in page) {
        final decisions = await _db.rows(
          'SELECT action,decision_canonical,operation_canonical FROM staging_import_decision WHERE job_id=? AND decision_id=?',
          [Variable(jobId), Variable('row:${row.row}')],
        );
        if (decisions.length != 1) {
          throw DomainFailure(
            'import_undecided_rows',
            'Row ${row.row} requires an explicit decision',
          );
        }
        final saved =
            jsonDecode(decisions.single.read<String>('decision_canonical'))
                as Map;
        if (canonicalJson((saved['confirmation_details'] as Map)['mapping']) !=
            canonicalJson(mapping.configuration)) {
          throw const DomainFailure(
            'import_mapping_changed',
            'Mapping changed after row confirmation; restart with a new task',
          );
        }
        switch (decisions.single.read<String>('action')) {
          case 'apply':
            applied++;
            final operation =
                jsonDecode(decisions.single.read<String>('operation_canonical'))
                    as Map;
            switch (operation['intent']) {
              case 'modify':
                modified++;
              case 'newInquiry':
                newInquiries++;
              case 'importHistorical':
                historical++;
            }
          case 'skip':
            skipped++;
          case 'excludeError':
            excluded++;
        }
      }
      cursor = page.last.row;
    }
    final counts = await _db.rows(
      'SELECT COUNT(*) count FROM staging_import_result WHERE job_id=?',
      [Variable(jobId)],
    );
    results = counts.single.read<int>('count');
    return BusinessImportSummary(
      applied,
      skipped,
      excluded,
      results,
      modified: modified,
      newInquiries: newInquiries,
      historical: historical,
    );
  }

  Future<BusinessConfirmation> seal() async {
    await summary();
    return exchange.sealBusiness(jobId);
  }

  static String _uuid() {
    final raw = newStorageId().substring(0, 32);
    return '${raw.substring(0, 8)}-${raw.substring(8, 12)}-4${raw.substring(13, 16)}-8${raw.substring(17, 20)}-${raw.substring(20)}';
  }

  String _timestamp() => DateTime.fromMillisecondsSinceEpoch(
    clock().millisecondsSinceEpoch,
    isUtc: true,
  ).toIso8601String();
}
