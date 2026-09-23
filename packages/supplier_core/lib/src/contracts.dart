/// Stable failure codes cross the service/UI boundary; technical causes stay
/// available to local diagnostics without being mistaken for success receipts.
final class DomainFailure implements Exception {
  const DomainFailure(this.code, this.message, {this.field, this.cause});
  final String code;
  final String message;
  final String? field;
  final Object? cause;
  @override
  String toString() => '$code: $message';
}

enum CaptureMode { standard, historical }

enum InquiryPrecision { date, instant, unknown }

enum RowAction { modify, newInquiry, skip }

enum JobState {
  created,
  parsing,
  validating,
  previewReady,
  committing,
  committed,
  cancelled,
  failed,
}

/// A repeatable bounded input. Each range is [start, endExclusive).
/// Implementations report unavailable/lost file handles instead of substituting
/// another source under an existing job's identity.
abstract interface class InputSource {
  String get displayName;
  Future<int> length();
  Stream<List<int>> openRange(int start, int endExclusive);
}

/// A temporary output is published only after complete generation and checking.
/// Browser download publication may mean "initiated", not physically saved.
abstract interface class OutputTarget {
  Future<void> write(Stream<List<int>> bytes);
  Future<void> publish();
  Future<void> abort();
}

/// Platform implementation must serialize all writers of one installation.
/// Acquire before opening a business SQL transaction; nested services receive
/// the existing locked context rather than reacquiring a non-reentrant lock.
abstract interface class ApplicationWriteLock {
  Future<T> run<T>(Future<T> Function() action);
}

/// An unforgeable, short-lived capability for composing operations under the
/// same non-reentrant installation lock. Never retain it beyond the callback.
final class ApplicationWriteContext {
  ApplicationWriteContext._(this._lock);
  final ApplicationWriteLock _lock;
  bool _active = true;

  void requireHeld(ApplicationWriteLock lock) {
    if (!_active || !identical(lock, _lock)) {
      throw StateError('Write context is expired or belongs to another lock');
    }
  }
}

Future<T> withApplicationWriteContext<T>(
  ApplicationWriteLock lock,
  Future<T> Function(ApplicationWriteContext context) action,
) => lock.run(() async {
  final context = ApplicationWriteContext._(lock);
  try {
    return await action(context);
  } finally {
    context._active = false;
  }
});

/// Version of the active business database, not staging progress.
final class DatabaseVersion {
  const DatabaseVersion({
    required this.instanceId,
    required this.activeEpoch,
    required this.generation,
  });
  final String instanceId;
  final int activeEpoch;
  final int generation;
}

/// UI may transport this token, but the coordinator must revalidate its inputs.
final class PreviewToken {
  const PreviewToken({
    required this.version,
    required this.jobId,
    required this.sealedStagingDigest,
    required this.decisionsDigest,
    required this.schemaVersion,
  });
  final DatabaseVersion version;
  final String jobId;
  final String sealedStagingDigest;
  final String decisionsDigest;
  final int schemaVersion;
  bool matches({
    required DatabaseVersion version,
    required String jobId,
    required String sealedStagingDigest,
    required String decisionsDigest,
    int schemaVersion = 2,
  }) =>
      this.version.instanceId == version.instanceId &&
      this.version.activeEpoch == version.activeEpoch &&
      this.version.generation == version.generation &&
      this.jobId == jobId &&
      this.sealedStagingDigest == sealedStagingDigest &&
      this.decisionsDigest == decisionsDigest &&
      this.schemaVersion == schemaVersion;
}

final class ScanPage<T> {
  factory ScanPage(List<T> values, {String? nextCursor, required int limit}) {
    if (limit < 1 || limit > 5000 || values.length > limit) {
      throw ArgumentError('Scan page exceeds its positive bounded limit');
    }
    if (values.isEmpty && nextCursor != null) {
      throw ArgumentError('An empty page cannot advance a cursor');
    }
    return ScanPage._(List<T>.unmodifiable(values), nextCursor);
  }
  ScanPage._(this.items, this.nextCursor);
  final List<T> items;
  final String? nextCursor;
}

/// Bound before the first read; discard the scan if the version changes.
abstract interface class RevisionScan<T> {
  DatabaseVersion get version;
  Future<ScanPage<T>> readPage({String? after, int limit = 500});
  Future<void> close();
}

abstract interface class RevisionReadStore<T> {
  Future<DatabaseVersion> currentVersion();
  Future<T?> findRevision(String revisionId);
  Future<RevisionScan<T>> openScan();
}

/// Opaque proof reserved for the future T4 validator in this library.
/// UI callers transport preview tokens, never construct trusted validation.
abstract base class ValidatedChangeSet {
  ValidatedChangeSet._();
  PreviewToken get token;
  int get validatorVersion;
}

/// Implementation owns app-lock -> identity check -> SQL ordering.
/// Full-history List submission is deliberately absent.
abstract interface class TransactionPort {
  Future<CommitReceipt> commitStaged({
    required String jobId,
    required PreviewToken expectedPreviewToken,
    required String confirmationEventId,
    ApplicationWriteContext? context,
  });
  Future<CommitReceipt?> findCommittedEvent(String confirmationEventId);
}

final class CommitReceipt {
  const CommitReceipt({
    required this.confirmationEventId,
    required this.version,
    required this.resultCount,
    required this.resultCursor,
  });
  final String confirmationEventId;
  final DatabaseVersion version;
  final int resultCount;

  /// A storage cursor pages results instead of collecting every imported ID.
  final String resultCursor;
}
