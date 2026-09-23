/// Shared domain, platform-neutral SQLite storage and application services.
library;

export 'src/contracts.dart';
export 'src/domain/canonical.dart';
export 'src/domain/entities.dart';
export 'src/domain/quotation.dart';
export 'src/domain/revision.dart';
export 'src/domain/revision_graph.dart';
export 'src/domain/values.dart';

export 'src/application/record_service.dart';
export 'src/application/backup_service.dart';
export 'src/exchange/backup_format.dart';
export 'src/exchange/space_budget.dart';
export 'src/exchange/restore_space.dart';
export 'src/data/database.dart' show SupplierDatabase;
export 'src/data/migrations.dart' show migrateStorageV2ToV3;
export 'src/data/tables.dart'
    show currentStorageSchemaVersion, businessSchemaVersion;
export 'src/data/commit_coordinator.dart'
    show CommitCoordinator, CommitFault, newStorageId;

export 'src/query/query_repository.dart'
    show QueryRepository, QueryPage, QuotationRow, EntityRow;
export 'src/query/candidates.dart' show Candidate, SearchMode;
export 'src/query/comparison.dart' show comparisonGroup, comparisonIssues;

export 'src/application/backup_candidate.dart';

export 'src/data/candidate_digest.dart';

export 'src/exchange/job_store.dart';

export 'src/exchange/xlsx_reader.dart';

export 'src/exchange/xlsx_staging.dart';

export 'src/exchange/xlsx_writer.dart';

export 'src/exchange/business_mapping.dart'
    show
        RawBusinessCell,
        BusinessCellKind,
        ExcelDateConversion,
        businessSourceCell;

export 'src/exchange/bounded_zip.dart' show XlsxZipLimits;
export 'src/exchange/import_receipts.dart'
    show
        ImportDecisionAction,
        ImportReceiptPage,
        ImportReceiptResultPage,
        SuccessfulImportOperation,
        ReceiptCursor,
        ReceiptResultCursor;
export 'src/exchange/business_import.dart';
export 'src/application/exchange_service.dart';
export 'src/application/business_import_workflow.dart';
export 'src/application/bundle_exchange_service.dart';
export 'src/exchange/business_preview.dart';
export 'src/exchange/bundle_manifest.dart';
export 'src/exchange/projection_digest.dart';
export 'src/exchange/bundle_import.dart';
export 'src/exchange/bundle_export.dart';
export 'src/exchange/bundle_database.dart';
