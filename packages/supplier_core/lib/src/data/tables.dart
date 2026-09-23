import 'graph_workspace.dart';

const terminalStagingDeleteGuard =
    "AND NOT EXISTS(SELECT 1 FROM import_job j WHERE j.job_id=OLD.job_id AND (j.state IN ('cancelled','failed') OR (j.state='committed' AND EXISTS(SELECT 1 FROM confirmation_event e JOIN commit_receipt r ON r.event_id=e.event_id WHERE e.job_id=j.job_id))))";

const projectionValueColumns =
    '''payload TEXT, relation_status TEXT NOT NULL, name TEXT,supplier_id TEXT,product_id TEXT,canonical_supplier_id TEXT,canonical_product_id TEXT,canonical_contact_id TEXT,search_text TEXT,price_key TEXT,currency TEXT,unit_snapshot TEXT,tax_mode TEXT,min_qty TEXT,tax_rate TEXT,project_name TEXT,project_number TEXT,inquiry_location TEXT,inquirer_name TEXT,inquiry_precision TEXT,inquiry_date TEXT,inquired_at TEXT,quoted_on TEXT,valid_until TEXT,brand TEXT,model TEXT,contact_id TEXT,capture_mode TEXT,missing_context TEXT,name_key TEXT,brand_key TEXT,model_key TEXT,project_name_key TEXT,project_number_key TEXT,inquirer_name_key TEXT,missing_context_count INTEGER''';

/// Protocol-2 authority and local durable work schema. Projection semantics are
/// deliberately owned by T4; creating these tables does not validate a graph.
final legacyStorageV2Statements = <String>[
  ...graphSchema,
  // User preferences only. Installation/device identity belongs to platform metadata.
  'CREATE TABLE local_settings(key TEXT PRIMARY KEY,value_json TEXT NOT NULL CHECK(json_valid(value_json)))',
  '''CREATE TABLE database_meta(singleton INTEGER PRIMARY KEY CHECK(singleton=1), instance_id TEXT NOT NULL, active_epoch INTEGER NOT NULL CHECK(active_epoch>=0), generation INTEGER NOT NULL CHECK(generation>=0), schema_version INTEGER NOT NULL CHECK(schema_version=2))''',
  '''CREATE TABLE entity_identity(entity_type TEXT NOT NULL CHECK(entity_type IN ('supplier','contact','product','quotation')), entity_id TEXT NOT NULL, PRIMARY KEY(entity_type,entity_id), UNIQUE(entity_id))''',
  '''CREATE TABLE revision(revision_id TEXT PRIMARY KEY, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, canonical TEXT NOT NULL, UNIQUE(revision_id,entity_type,entity_id), FOREIGN KEY(entity_type,entity_id) REFERENCES entity_identity(entity_type,entity_id))''',
  'CREATE INDEX revision_entity ON revision(entity_type,entity_id,revision_id)',
  '''CREATE TABLE revision_parent(child_id TEXT NOT NULL REFERENCES revision(revision_id) DEFERRABLE INITIALLY DEFERRED, parent_id TEXT NOT NULL REFERENCES revision(revision_id) DEFERRABLE INITIALLY DEFERRED, PRIMARY KEY(child_id,parent_id), CHECK(child_id<>parent_id))''',
  'CREATE INDEX parent_children ON revision_parent(parent_id,child_id)',
  '''CREATE TABLE entity_head(entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, revision_id TEXT NOT NULL, PRIMARY KEY(entity_type,entity_id,revision_id), FOREIGN KEY(revision_id,entity_type,entity_id) REFERENCES revision(revision_id,entity_type,entity_id))''',
  for (final type in ['supplier', 'contact', 'product', 'quotation'])
    "CREATE TABLE ${type}_projection(entity_id TEXT PRIMARY KEY, entity_type TEXT NOT NULL DEFAULT '$type' CHECK(entity_type='$type'),revision_id TEXT,$projectionValueColumns,FOREIGN KEY(revision_id,entity_type,entity_id) REFERENCES revision(revision_id,entity_type,entity_id))",
  "CREATE TABLE quotation_head_projection(entity_id TEXT NOT NULL,entity_type TEXT NOT NULL DEFAULT 'quotation' CHECK(entity_type='quotation'),revision_id TEXT PRIMARY KEY,$projectionValueColumns,FOREIGN KEY(revision_id,entity_type,entity_id) REFERENCES revision(revision_id,entity_type,entity_id))",
  'CREATE INDEX quotation_heads_entity ON quotation_head_projection(entity_id,revision_id)',
  'CREATE TABLE candidate_term(entity_type TEXT NOT NULL,entity_id TEXT NOT NULL,field TEXT NOT NULL,search_key TEXT NOT NULL,original_text TEXT NOT NULL,PRIMARY KEY(entity_type,field,search_key,entity_id))',
  'CREATE INDEX candidate_owner ON candidate_term(entity_type,entity_id)',
  for (final table in [
    'quotation_projection',
    'quotation_head_projection',
  ]) ...[
    'CREATE INDEX ${table}_contact_original ON $table(contact_id,entity_id)',
    'CREATE INDEX ${table}_contact_canonical ON $table(canonical_contact_id,entity_id)',
    'CREATE INDEX ${table}_product_original ON $table(product_id,entity_id)',
    'CREATE INDEX ${table}_supplier_original ON $table(supplier_id,entity_id)',
    'CREATE INDEX ${table}_status ON $table(relation_status,entity_id)',
    'CREATE INDEX ${table}_product_date ON $table(canonical_product_id,quoted_on DESC,entity_id)',
    'CREATE INDEX ${table}_supplier_date ON $table(canonical_supplier_id,quoted_on DESC,entity_id)',
    'CREATE INDEX ${table}_project_date ON $table(project_number_key,inquiry_date DESC,entity_id)',
    'CREATE INDEX ${table}_inquirer_date ON $table(inquirer_name_key,inquiry_date DESC,entity_id)',
    'CREATE INDEX ${table}_compare ON $table(canonical_product_id,unit_snapshot,currency,tax_mode,min_qty,tax_rate,price_key,entity_id)',
    "CREATE INDEX ${table}_quoted_order ON $table(COALESCE(quoted_on,'') DESC,entity_id)",
    "CREATE INDEX ${table}_inquiry_order ON $table(COALESCE(inquiry_date,'') DESC,entity_id)",
    "CREATE INDEX ${table}_price_order ON $table(COALESCE(price_key,'~'),entity_id)",
  ],
  for (final type in ['supplier', 'contact', 'product', 'quotation']) ...[
    'CREATE INDEX ${type}_projection_name ON ${type}_projection(name,entity_id)',
    'CREATE INDEX ${type}_projection_supplier ON ${type}_projection(canonical_supplier_id,entity_id)',
    'CREATE INDEX ${type}_projection_product ON ${type}_projection(canonical_product_id,entity_id)',
  ],
  'CREATE INDEX quotation_price ON quotation_projection(currency,unit_snapshot,tax_mode,price_key,entity_id)',
  'CREATE INDEX quotation_date ON quotation_projection(inquiry_date,entity_id)',
  'CREATE INDEX quotation_project ON quotation_projection(project_number,entity_id)',
  '''CREATE TABLE reference_projection(source_type TEXT NOT NULL, source_id TEXT NOT NULL, field TEXT NOT NULL, target_type TEXT NOT NULL, target_id TEXT NOT NULL, PRIMARY KEY(source_type,source_id,field,target_type,target_id), FOREIGN KEY(source_type,source_id) REFERENCES entity_identity(entity_type,entity_id), FOREIGN KEY(target_type,target_id) REFERENCES entity_identity(entity_type,entity_id))''',
  'CREATE INDEX reference_target ON reference_projection(target_type,target_id,source_type,source_id)',
  '''CREATE TABLE alias_projection(entity_type TEXT NOT NULL, entity_id TEXT NOT NULL, canonical_id TEXT, relation_status TEXT NOT NULL, PRIMARY KEY(entity_type,entity_id), FOREIGN KEY(entity_type,entity_id) REFERENCES entity_identity(entity_type,entity_id), FOREIGN KEY(entity_type,canonical_id) REFERENCES entity_identity(entity_type,entity_id))''',
  '''CREATE TABLE import_job(job_id TEXT PRIMARY KEY, state TEXT NOT NULL CHECK(state IN ('created','parsing','validating','previewReady','committing','committed','cancelled','failed')), sealed_digest TEXT, decisions_digest TEXT, CHECK((sealed_digest IS NULL)=(decisions_digest IS NULL)))''',
  'CREATE TABLE job_input(job_id TEXT PRIMARY KEY REFERENCES import_job(job_id),source_length INTEGER NOT NULL CHECK(source_length>=0),source_digest TEXT,instance_id TEXT NOT NULL,active_epoch INTEGER NOT NULL,generation INTEGER NOT NULL,schema_version INTEGER NOT NULL,replaces_job_id TEXT REFERENCES import_job(job_id))',
  "CREATE TRIGGER job_input_binding BEFORE UPDATE OF source_length,source_digest ON job_input WHEN OLD.source_digest IS NOT NULL BEGIN SELECT RAISE(ABORT,'source binding is immutable'); END",
  '''CREATE TABLE staging_revision(job_id TEXT NOT NULL REFERENCES import_job(job_id), revision_id TEXT NOT NULL, canonical TEXT NOT NULL, PRIMARY KEY(job_id,revision_id))''',
  for (final operation in ['INSERT', 'UPDATE', 'DELETE'])
    '''CREATE TRIGGER staging_seal_${operation.toLowerCase()} BEFORE $operation ON staging_revision WHEN (SELECT sealed_digest FROM import_job WHERE job_id=${operation == 'DELETE' ? 'OLD' : 'NEW'}.job_id) IS NOT NULL ${operation == 'DELETE' ? terminalStagingDeleteGuard : ''} ${operation == 'UPDATE' ? "OR (SELECT sealed_digest FROM import_job WHERE job_id=OLD.job_id) IS NOT NULL" : ''} BEGIN SELECT RAISE(ABORT,'staging is sealed'); END''',
  '''CREATE TRIGGER job_seal BEFORE UPDATE OF sealed_digest,decisions_digest ON import_job WHEN OLD.sealed_digest IS NOT NULL BEGIN SELECT RAISE(ABORT,'seal is immutable'); END''',
  'CREATE TABLE staging_expected_entity(job_id TEXT NOT NULL REFERENCES import_job(job_id),entity_type TEXT NOT NULL,entity_id TEXT NOT NULL,PRIMARY KEY(job_id,entity_type,entity_id))',
  'CREATE TABLE staging_expected_head(job_id TEXT NOT NULL,entity_type TEXT NOT NULL,entity_id TEXT NOT NULL,revision_id TEXT NOT NULL,PRIMARY KEY(job_id,entity_type,entity_id,revision_id),FOREIGN KEY(job_id,entity_type,entity_id) REFERENCES staging_expected_entity(job_id,entity_type,entity_id))',
  for (final table in ['staging_expected_entity', 'staging_expected_head'])
    for (final operation in ['INSERT', 'UPDATE', 'DELETE'])
      "CREATE TRIGGER ${table}_${operation.toLowerCase()} BEFORE $operation ON $table WHEN (SELECT sealed_digest FROM import_job WHERE job_id=${operation == 'DELETE' ? 'OLD' : 'NEW'}.job_id) IS NOT NULL ${operation == 'DELETE' ? terminalStagingDeleteGuard : ''} ${operation == 'UPDATE' ? "OR (SELECT sealed_digest FROM import_job WHERE job_id=OLD.job_id) IS NOT NULL" : ''} BEGIN SELECT RAISE(ABORT,'expected heads are sealed'); END",
  '''CREATE TABLE confirmation_event(event_id TEXT PRIMARY KEY, job_id TEXT NOT NULL REFERENCES import_job(job_id), sealed_digest TEXT NOT NULL, decisions_digest TEXT NOT NULL, instance_id TEXT NOT NULL, active_epoch INTEGER NOT NULL, generation INTEGER NOT NULL, schema_version INTEGER NOT NULL CHECK(schema_version=2))''',
  'CREATE INDEX confirmation_job ON confirmation_event(job_id,event_id)',
  '''CREATE TABLE commit_receipt(event_id TEXT PRIMARY KEY REFERENCES confirmation_event(event_id), instance_id TEXT NOT NULL, active_epoch INTEGER NOT NULL, generation INTEGER NOT NULL, result_count INTEGER NOT NULL)''',
  '''CREATE TABLE receipt_result(event_id TEXT NOT NULL REFERENCES confirmation_event(event_id), revision_id TEXT NOT NULL REFERENCES revision(revision_id), PRIMARY KEY(event_id,revision_id))''',
  '''CREATE TABLE import_row_receipt(event_id TEXT NOT NULL REFERENCES confirmation_event(event_id), fingerprint_version INTEGER NOT NULL CHECK(fingerprint_version=1), source_fingerprint TEXT NOT NULL, operation_fingerprint TEXT NOT NULL, original_target_id TEXT NOT NULL, result_revision_id TEXT NOT NULL REFERENCES revision(revision_id), PRIMARY KEY(event_id,source_fingerprint,operation_fingerprint,result_revision_id))''',
  'CREATE INDEX receipt_source ON import_row_receipt(fingerprint_version,source_fingerprint)',
];

const currentStorageSchemaVersion = 3;
const businessSchemaVersion = 2;

final storageV3Statements = <String>[
  "CREATE TABLE staging_import_decision(job_id TEXT NOT NULL REFERENCES import_job(job_id),decision_id TEXT NOT NULL,action TEXT NOT NULL CHECK(action IN ('apply','skip','excludeError')),fingerprint_version INTEGER NOT NULL CHECK(fingerprint_version=1),source_fingerprint TEXT,source_canonical TEXT,operation_fingerprint TEXT,operation_canonical TEXT,original_target_id TEXT NOT NULL,decision_canonical TEXT NOT NULL,exclusion_reason TEXT,PRIMARY KEY(job_id,decision_id),CHECK((operation_fingerprint IS NULL)=(operation_canonical IS NULL)),CHECK((source_fingerprint IS NULL)=(source_canonical IS NULL)),CHECK(action='excludeError' OR source_fingerprint IS NOT NULL),CHECK((action='apply' AND operation_fingerprint IS NOT NULL) OR (action<>'apply' AND operation_fingerprint IS NULL)))",
  "CREATE UNIQUE INDEX staging_apply_unique ON staging_import_decision(job_id,source_fingerprint,operation_fingerprint) WHERE action='apply'",
  'CREATE TABLE staging_import_result(job_id TEXT NOT NULL,decision_id TEXT NOT NULL,result_revision_id TEXT NOT NULL,PRIMARY KEY(job_id,decision_id,result_revision_id),FOREIGN KEY(job_id,decision_id) REFERENCES staging_import_decision(job_id,decision_id),FOREIGN KEY(job_id,result_revision_id) REFERENCES staging_revision(job_id,revision_id))',
  for (final operation in ['INSERT', 'UPDATE'])
    "CREATE TRIGGER staging_result_apply_${operation.toLowerCase()} BEFORE $operation ON staging_import_result WHEN NOT EXISTS(SELECT 1 FROM staging_import_decision d WHERE d.job_id=NEW.job_id AND d.decision_id=NEW.decision_id AND d.action='apply') BEGIN SELECT RAISE(ABORT,'result requires apply decision'); END",
  "CREATE TRIGGER staging_decision_apply BEFORE UPDATE OF action ON staging_import_decision WHEN NEW.action<>'apply' AND EXISTS(SELECT 1 FROM staging_import_result r WHERE r.job_id=OLD.job_id AND r.decision_id=OLD.decision_id) BEGIN SELECT RAISE(ABORT,'non-apply decision has results'); END",
  'CREATE TABLE import_decision_receipt(event_id TEXT NOT NULL REFERENCES confirmation_event(event_id),fingerprint_version INTEGER NOT NULL CHECK(fingerprint_version=1),source_fingerprint TEXT NOT NULL,operation_fingerprint TEXT NOT NULL,source_canonical TEXT NOT NULL,operation_canonical TEXT NOT NULL,original_target_id TEXT NOT NULL,PRIMARY KEY(event_id,source_fingerprint,operation_fingerprint))',
  'CREATE INDEX decision_receipt_source ON import_decision_receipt(fingerprint_version,source_fingerprint,event_id,operation_fingerprint)',
  for (final table in ['staging_import_decision', 'staging_import_result'])
    for (final operation in ['INSERT', 'UPDATE', 'DELETE'])
      "CREATE TRIGGER ${table}_${operation.toLowerCase()} BEFORE $operation ON $table WHEN (SELECT sealed_digest FROM import_job WHERE job_id=${operation == 'DELETE' ? 'OLD' : 'NEW'}.job_id) IS NOT NULL ${operation == 'DELETE' ? terminalStagingDeleteGuard : ''} ${operation == 'UPDATE' ? "OR (SELECT sealed_digest FROM import_job WHERE job_id=OLD.job_id) IS NOT NULL" : ''} BEGIN SELECT RAISE(ABORT,'import decisions are sealed'); END",
];

List<String> schemaStatementsForVersion(int version) => switch (version) {
  2 => List.unmodifiable(legacyStorageV2Statements),
  3 => List.unmodifiable([
    ...legacyStorageV2Statements,
    ...storageV3Statements,
  ]),
  _ => throw ArgumentError.value(version, 'storageVersion'),
};
final schemaStatements = schemaStatementsForVersion(
  currentStorageSchemaVersion,
);
