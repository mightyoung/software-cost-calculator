import '../contracts.dart';
import '../domain/revision.dart';
import 'import_receipts.dart';

/// Explicit policy for the bounded workbook adapter. Its ZIP limits still apply;
/// callers must not advertise this adapter as unrestricted large-workbook input.
final class BusinessWorkbookPolicy {
  BusinessWorkbookPolicy({required this.maxDataRows}) {
    RangeError.checkValueInInterval(maxDataRows, 1, 1048575, 'maxDataRows');
  }
  final int maxDataRows;
}

/// A durable, readable published backup destination, owned by the platform.
/// A download-only target cannot meet the pre-import backup requirement.
final class BusinessBackupDestination {
  const BusinessBackupDestination(this.output, this.source, {this.onVerified});
  final OutputTarget output;
  final InputSource source;
  final Future<void> Function(String jobId)? onVerified;
}

/// Caller-provided mapping, chosen bindings and preallocated IDs/timestamps.
/// The service does not infer ambiguous candidate matches or field operations.
final class BusinessImportDecision {
  const BusinessImportDecision({
    required this.id,
    required this.action,
    required this.originalTargetId,
    required this.confirmationDetails,
    this.source,
    this.operation,
    this.exclusionReason,
    this.revisions = const [],
    this.resultRevisionIds = const [],
  });
  final String id, originalTargetId;
  final ImportDecisionAction action;
  final SourceFingerprint? source;
  final OperationFingerprint? operation;
  final Map<String, Object?> confirmationDetails;
  final String? exclusionReason;
  final Iterable<RevisionEnvelope> revisions;
  final Iterable<String> resultRevisionIds;
}

final class BusinessConfirmation {
  const BusinessConfirmation(this.token, this.eventId);
  final PreviewToken token;
  final String eventId;
}

final class BusinessExportSummary {
  const BusinessExportSummary({
    required this.version,
    required this.rows,
    required this.byteLength,
    required this.sha256,
  });
  final DatabaseVersion version;
  final int rows, byteLength;
  final String sha256;
}
