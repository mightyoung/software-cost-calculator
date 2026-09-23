import '../contracts.dart';
import '../data/database.dart';
import '../domain/values.dart';
import 'space_budget.dart';

/// A point-in-time estimate, never a reservation or a physical free-disk claim.
final class CapacitySample {
  CapacitySample({
    required this.status,
    required this.scope,
    this.availableBytes,
    this.usageBytes,
    this.quotaBytes,
    this.diagnostic,
    DateTime? sampledAt,
  }) : sampledAt = sampledAt ?? DateTime.now().toUtc() {
    if (availableBytes != null) {
      requireSafeInteger(availableBytes, 'available_bytes', min: 0);
    }
    for (final value in [usageBytes, quotaBytes]) {
      if (value != null) requireSafeInteger(value, 'capacity_bytes', min: 0);
    }
    if (!{'estimated', 'unsupported', 'failed', 'invalid'}.contains(status)) {
      throw ArgumentError.value(status, 'status');
    }
    if ((status == 'estimated') != (availableBytes != null)) {
      throw ArgumentError('Only estimated capacity has an available value');
    }
  }
  final String status, scope;
  final int? availableBytes;
  final int? usageBytes, quotaBytes;
  final Object? diagnostic;
  final DateTime sampledAt;

  static Future<CapacitySample> nativeUnknown() async =>
      CapacitySample(status: 'unsupported', scope: 'native-filesystem-unknown');
  Map<String, Object?> toJson() => {
    'status': status,
    'scope': scope,
    'available_bytes': availableBytes,
    'usage_bytes': usageBytes,
    'quota_bytes': quotaBytes,
    'sampled_at': sampledAt.toIso8601String(),
    if (diagnostic != null) 'diagnostic': diagnostic.toString(),
  };
}

typedef CapacityReader = Future<CapacitySample> Function();

/// Initial heuristic, intentionally versioned for later measured calibration.
/// Existing files are included in platform usage, not charged again as new bytes.
final class RestoreSpaceEstimate {
  RestoreSpaceEstimate({
    required this.version,
    required this.phase,
    required this.capacity,
    required int activeBytes,
    int sourceBytes = 0,
    int candidateBytes = 0,
  }) {
    if (phase != 'prepare' && phase != 'activate') {
      throw ArgumentError.value(phase, 'phase');
    }
    for (final value in [activeBytes, sourceBytes, candidateBytes]) {
      requireSafeInteger(value, 'estimate_bytes', min: 0);
    }
    final a = BigInt.from(activeBytes), s = BigInt.from(sourceBytes);
    final c = BigInt.from(candidateBytes), m = BigInt.from(1024 * 1024);
    final backup = a * BigInt.two + m;
    final prepare = phase == 'prepare';
    basis = Map.unmodifiable({
      'active_bytes': activeBytes,
      'source_bytes': sourceBytes,
      'candidate_bytes': candidateBytes,
    });
    budget = SpaceBudget(
      availableBytes: capacity.availableBytes,
      components: {
        'staging': _safe(prepare ? s * BigInt.two : BigInt.zero),
        'candidate_increment': _safe(
          prepare ? s * BigInt.from(4) : BigInt.zero,
        ),
        'transaction_journal': _safe(
          prepare ? s * BigInt.from(6) + m : a + c + m,
        ),
        'safety_backup_private': _safe(backup),
        'safety_backup_published': _safe(backup),
        'metadata_and_slack': _safe(m),
      },
    );
  }
  static const policy = 'restore-space-v1';
  final DatabaseVersion version;
  final String phase;
  final CapacitySample capacity;
  late final Map<String, int> basis;
  late final SpaceBudget budget;

  void requireAvailable() {
    if (budget.fits == false) {
      throw DomainFailure(
        'SPACE_REQUIRED',
        'Insufficient estimated restore space',
        cause: toJson(),
      );
    }
  }

  Map<String, Object?> toJson() => {
    'policy': policy,
    'heuristic': true,
    'phase': phase,
    'instance_id': version.instanceId,
    'epoch': version.activeEpoch,
    'generation': version.generation,
    'basis': basis,
    'components': budget.components,
    'estimated_bytes': budget.estimatedBytes.toString(),
    'fits': budget.fits,
    'capacity': capacity.toJson(),
  };
}

/// SQLite allocated main-database pages, excluding WAL and temporary files.
Future<int> databaseAllocatedBytes(SupplierDatabase database) async {
  final pages = (await database.rows(
    'PRAGMA page_count',
  )).single.read<int>('page_count');
  final size = (await database.rows(
    'PRAGMA page_size',
  )).single.read<int>('page_size');
  return _safe(BigInt.from(pages) * BigInt.from(size));
}

int _safe(BigInt value) {
  if (value < BigInt.zero || value > BigInt.from(9007199254740991)) {
    throw const DomainFailure(
      'SPACE_ESTIMATE_RANGE',
      'Space estimate exceeds exact integer range',
    );
  }
  return value.toInt();
}
