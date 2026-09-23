part of 'commit_coordinator.dart';

/// Internal storage installation used only after the coordinator's real union
/// validation. Conflicts retain an explicit summary, never an arbitrary winner.
Future<void> _installGraphProjections(
  SupplierDatabase db,
  SqlGraphWorkspace work, {
  int pageSize = 500,
}) async {
  // Recompute only changed heads/relations, then indexed dependent closure.
  // Relation comparison captures an entire changed redirect component, including
  // entities whose own revision did not change.
  await db.customStatement(
    "INSERT INTO graph_affected SELECT g.run_id,g.entity_type,g.entity_id FROM graph_entity g LEFT JOIN graph_relation n ON n.run_id=g.run_id AND n.entity_type=g.entity_type AND n.entity_id=g.entity_id LEFT JOIN alias_projection old ON old.entity_type=g.entity_type AND old.entity_id=g.entity_id WHERE g.run_id=? AND (old.entity_id IS NULL OR old.relation_status IS NOT n.status OR old.canonical_id IS NOT n.canonical_id OR EXISTS(SELECT revision_id FROM graph_head WHERE run_id=g.run_id AND entity_type=g.entity_type AND entity_id=g.entity_id EXCEPT SELECT revision_id FROM entity_head WHERE entity_type=g.entity_type AND entity_id=g.entity_id) OR EXISTS(SELECT revision_id FROM entity_head WHERE entity_type=g.entity_type AND entity_id=g.entity_id EXCEPT SELECT revision_id FROM graph_head WHERE run_id=g.run_id AND entity_type=g.entity_type AND entity_id=g.entity_id))",
    [work.runId],
  );
  while (true) {
    final added = await db.customUpdate(
      'INSERT INTO graph_affected SELECT DISTINCT ?,r.source_type,r.source_id FROM reference_projection r JOIN graph_affected a ON a.run_id=? AND a.entity_type=r.target_type AND a.entity_id=r.target_id WHERE true ON CONFLICT DO NOTHING',
      variables: [Variable(work.runId), Variable(work.runId)],
    );
    if (added == 0) break;
  }
  for (final table in ['entity_head', 'alias_projection']) {
    await db.customStatement(
      'DELETE FROM $table WHERE (entity_type,entity_id) IN (SELECT entity_type,entity_id FROM graph_affected WHERE run_id=?)',
      [work.runId],
    );
  }
  await db.customStatement(
    'INSERT INTO entity_head SELECT h.entity_type,h.entity_id,h.revision_id FROM graph_head h JOIN graph_affected a ON a.run_id=h.run_id AND a.entity_type=h.entity_type AND a.entity_id=h.entity_id WHERE h.run_id=?',
    [work.runId],
  );
  await db.customStatement(
    'INSERT INTO alias_projection SELECT r.entity_type,r.entity_id,r.canonical_id,r.status FROM graph_relation r JOIN graph_affected a ON a.run_id=r.run_id AND a.entity_type=r.entity_type AND a.entity_id=r.entity_id WHERE r.run_id=?',
    [work.runId],
  );
  await db.customStatement(
    'DELETE FROM reference_projection WHERE (source_type,source_id) IN (SELECT entity_type,entity_id FROM graph_affected WHERE run_id=?)',
    [work.runId],
  );
  for (final type in ['supplier', 'contact', 'product', 'quotation']) {
    await db.customStatement(
      'DELETE FROM ${type}_projection WHERE entity_id IN (SELECT entity_id FROM graph_affected WHERE run_id=? AND entity_type=?)',
      [work.runId, type],
    );
  }
  await db.customStatement(
    'DELETE FROM quotation_head_projection WHERE entity_id IN (SELECT entity_id FROM graph_affected WHERE run_id=? AND entity_type=?)',
    [work.runId, 'quotation'],
  );
  await db.customStatement(
    'DELETE FROM candidate_term WHERE (entity_type,entity_id) IN (SELECT entity_type,entity_id FROM graph_affected WHERE run_id=?)',
    [work.runId],
  );
  String? cursor;
  do {
    final page = await work.readAffectedEntities(
      after: cursor,
      limit: pageSize,
    );
    for (final entity in page.items) {
      final relation = (await work.relation(entity))!;
      final head = (await work.headSummary(entity)).single;
      final fields = await _projectionFields(work, entity, relation, head);
      // The table name comes only from validated protocol entity types.
      await db.customStatement(
        'INSERT INTO ${entity.type}_projection(${fields.keys.join(',')}) VALUES(${List.filled(fields.length, '?').join(',')})',
        fields.values.toList(),
      );
      var hasCurrentPut = false;
      String? headCursor;
      do {
        final rows = await db.rows(
          'SELECT revision_id FROM graph_head WHERE run_id=? AND entity_type=? AND entity_id=? AND revision_id>? ORDER BY revision_id LIMIT ?',
          [
            Variable(work.runId),
            Variable(entity.type),
            Variable(entity.id),
            Variable(headCursor ?? ''),
            Variable(pageSize),
          ],
        );
        for (final row in rows) {
          final current = (await work.findRevision(
            row.read<String>('revision_id'),
          ))!;
          if (entity.type == 'quotation') {
            final values = await _projectionFields(
              work,
              entity,
              relation,
              current,
            );
            await db.customStatement(
              'INSERT INTO quotation_head_projection(${values.keys.join(',')}) VALUES(${List.filled(values.length, '?').join(',')})',
              values.values.toList(),
            );
          }
          if (current.envelope.kind == 'put') {
            hasCurrentPut = true;
            for (final field in ['supplier_id', 'product_id', 'contact_id']) {
              final target = current.envelope.payload[field];
              if (target == null) continue;
              await db.customStatement(
                'INSERT INTO reference_projection VALUES(?,?,?,?,?) ON CONFLICT DO NOTHING',
                [
                  entity.type,
                  entity.id,
                  field,
                  field.substring(0, field.length - 3),
                  target,
                ],
              );
            }

            for (final term in candidateTerms(
              entity.type,
              current.envelope.payload,
            )) {
              await db.customStatement(
                'INSERT INTO candidate_term VALUES(?,?,?,?,?) ON CONFLICT DO NOTHING',
                [entity.type, entity.id, term.$1, term.$2, term.$3],
              );
            }
          }
        }
        if (rows.length < pageSize) break;
        headCursor = rows.last.read<String>('revision_id');
      } while (true);
      // Tombstones/redirects have no chosen current put payload. Preserve all
      // historical identification terms in bounded pages for discovery only;
      // their deleted/redirect relation state remains explicit to callers.
      if (entity.type != 'quotation' && !hasCurrentPut) {
        String? historyCursor;
        do {
          final history = await db.rows(
            'SELECT revision_id,canonical FROM graph_revision WHERE run_id=? AND entity_type=? AND entity_id=? AND revision_id>? ORDER BY revision_id LIMIT ?',
            [
              Variable(work.runId),
              Variable(entity.type),
              Variable(entity.id),
              Variable(historyCursor ?? ''),
              Variable(pageSize),
            ],
          );
          for (final row in history) {
            final old = (await work.findRevision(
              row.read<String>('revision_id'),
            ))!;
            if (old.envelope.kind != 'put') continue;
            for (final term in candidateTerms(
              entity.type,
              old.envelope.payload,
            )) {
              await db.customStatement(
                'INSERT INTO candidate_term VALUES(?,?,?,?,?) ON CONFLICT DO NOTHING',
                [entity.type, entity.id, term.$1, term.$2, term.$3],
              );
            }
          }
          if (history.length < pageSize) break;
          historyCursor = history.last.read<String>('revision_id');
        } while (true);
      }
    }
    cursor = page.nextCursor;
  } while (cursor != null);
}

Future<Map<String, Object?>> _projectionFields(
  SqlGraphWorkspace work,
  GraphEntity entity,
  GraphRelation relation,
  GraphRevision? head,
) async {
  final payload = head?.envelope.kind == 'put' ? head!.envelope.payload : null;
  final supplier = payload?['supplier_id'] as String?;
  final product = payload?['product_id'] as String?;
  String? canonicalSupplier, canonicalProduct, canonicalContact;
  if (supplier != null) {
    canonicalSupplier = (await work.relation(
      GraphEntity('supplier', supplier),
    ))?.canonical?.id;
  }
  if (product != null) {
    canonicalProduct = (await work.relation(
      GraphEntity('product', product),
    ))?.canonical?.id;
  }
  if (payload?['contact_id'] != null) {
    canonicalContact = (await work.relation(
      GraphEntity('contact', payload!['contact_id']! as String),
    ))?.canonical?.id;
  }
  final fields = <String, Object?>{
    'entity_id': entity.id,
    'entity_type': entity.type,
    'revision_id': head?.id,
    'payload': payload == null ? null : jsonEncode(payload),
    'relation_status': relation.status.name,
    'name': payload?['name'],
    'supplier_id': supplier,
    'product_id': product,
    'canonical_supplier_id': canonicalSupplier,
    'canonical_product_id': canonicalProduct,
    'canonical_contact_id': canonicalContact,
    'search_text': payload == null ? null : searchKey(jsonEncode(payload)),
    ...projectionSearchKeys(payload),
    'missing_context_count': entity.type == 'quotation' && payload != null
        ? Quotation.fromJson(payload).missingContext.length
        : null,
    'price_key': entity.type == 'quotation' && payload != null
        ? Quotation.fromJson(payload).priceKey
        : null,
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
      name: payload?[name],
    'missing_context': entity.type == 'quotation' && payload != null
        ? jsonEncode(Quotation.fromJson(payload).missingContext)
        : null,
  };
  return fields;
}
