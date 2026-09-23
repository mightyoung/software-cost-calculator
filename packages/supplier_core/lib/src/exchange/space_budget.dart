import '../contracts.dart';

/// An estimate for admission messaging, never a substitute for transactional
/// handling of real quota, SQLITE_FULL, write, or close failures.
final class SpaceBudget {
  SpaceBudget({required Map<String, int> components, this.availableBytes})
    : components = Map.unmodifiable(components) {
    for (final entry in components.entries) {
      _bytes(entry.value, entry.key);
    }
    if (availableBytes != null) _bytes(availableBytes!, 'availableBytes');
  }
  final Map<String, int> components;
  final int? availableBytes;

  /// BigInt keeps accumulation exact on both VM and JavaScript. Unknown free
  /// space is reported as unknown; it is not fabricated as zero or unlimited.
  BigInt get estimatedBytes => components.values.fold(
    BigInt.zero,
    (total, value) => total + BigInt.from(value),
  );
  bool? get fits => availableBytes == null
      ? null
      : estimatedBytes <= BigInt.from(availableBytes!);

  void requireAvailable() {
    if (fits == false) {
      throw DomainFailure(
        'SPACE_REQUIRED',
        'Insufficient estimated working space',
        cause: {
          'required': estimatedBytes.toString(),
          'available': availableBytes,
        },
      );
    }
  }
}

/// Per-XLSX-volume limits. There is deliberately no whole-bundle size cap.
/// Count actual decompressed bytes before forwarding them to parsers or sinks.
final class VolumeBudget {
  static const maxCompressedBytes = 8 * 1024 * 1024;
  static const maxExpandedBytes = 32 * 1024 * 1024;
  static const maxEntries = 2048;
  static const maxDataRows = 5000;
  int _expandedBytes = 0, _entries = 0, _dataRows = 0;
  bool _failed = false;
  int get expandedBytes => _expandedBytes;
  int get entries => _entries;
  int get dataRows => _dataRows;

  void checkCompressedSize(int bytes) {
    _check(bytes, maxCompressedBytes, 'compressed_bytes');
  }

  void addExpandedBytes(int count) {
    _bytes(count, 'expanded_bytes');
    // Compare by subtraction so a hostile declared count cannot overflow JS's
    // exact integer range before the check.
    _check(count, maxExpandedBytes - _expandedBytes, 'expanded_bytes');
    _expandedBytes += count;
  }

  void addEntry() {
    _check(1, maxEntries - _entries, 'entries');
    _entries++;
  }

  void addDataRow() {
    _check(1, maxDataRows - _dataRows, 'data_rows');
    _dataRows++;
  }

  void _check(int count, int remaining, String field) {
    if (_failed) {
      throw const DomainFailure('VOLUME_LIMIT', 'Volume already rejected');
    }
    _bytes(count, field);
    if (count > remaining) {
      _failed = true;
      throw DomainFailure(
        'VOLUME_LIMIT',
        'XLSX volume exceeds its limit',
        field: field,
      );
    }
  }
}

void _bytes(int value, String field) {
  if (value < 0 || value > 9007199254740991) {
    throw ArgumentError.value(
      value,
      field,
      'Expected a nonnegative safe integer',
    );
  }
}
