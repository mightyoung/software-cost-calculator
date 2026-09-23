import 'dart:convert';

import 'package:crypto/crypto.dart';
import '../contracts.dart';
import '../domain/revision.dart';
import '../domain/canonical.dart';
import '../domain/values.dart';

/// Logical backup versions 1 and 2. This is independent of Excel synchronization.
/// Only durable business authority, preferences, and successful receipts belong
/// here. Installation identity, locks, caches and unfinished jobs are excluded.
const backupV1TableKeys = <String, List<String>>{
  'revision': ['revision_id'],
  'local_settings': ['key'],
  'import_job': ['job_id'],
  'confirmation_event': ['event_id'],
  'commit_receipt': ['event_id'],
  'receipt_result': ['event_id', 'revision_id'],
  'import_row_receipt': [
    'event_id',
    'source_fingerprint',
    'operation_fingerprint',
    'result_revision_id',
  ],
};

/// Byte identity for a private, closed candidate file. Each requested range is
/// checked independently; this does not replace logical backup validation.
Future<String> inputSha256(InputSource source) async {
  final digest = _Digest();
  final sink = sha256.startChunkedConversion(digest);
  final length = await source.length();
  for (var offset = 0; offset < length; offset += 65536) {
    final end = (offset + 65536).clamp(0, length);
    var received = 0;
    await for (final chunk in source.openRange(offset, end)) {
      received += chunk.length;
      if (received > end - offset) {
        throw const DomainFailure(
          'IO_FAILURE',
          'Source exceeded requested range',
        );
      }
      sink.add(chunk);
    }
    if (received != end - offset) {
      throw const DomainFailure(
        'IO_FAILURE',
        'Source ended before requested range',
      );
    }
  }
  sink.close();
  return digest.value.toString();
}

const backupV1TableColumns = <String, List<String>>{
  'revision': ['revision_id', 'entity_type', 'entity_id', 'canonical'],
  'local_settings': ['key', 'value_json'],
  'import_job': ['job_id', 'state', 'sealed_digest', 'decisions_digest'],
  'confirmation_event': [
    'event_id',
    'job_id',
    'sealed_digest',
    'decisions_digest',
    'instance_id',
    'active_epoch',
    'generation',
    'schema_version',
  ],
  'commit_receipt': [
    'event_id',
    'instance_id',
    'active_epoch',
    'generation',
    'result_count',
  ],
  'receipt_result': ['event_id', 'revision_id'],
  'import_row_receipt': [
    'event_id',
    'fingerprint_version',
    'source_fingerprint',
    'operation_fingerprint',
    'original_target_id',
    'result_revision_id',
  ],
};

const backupTableKeys = {
  ...backupV1TableKeys,
  'import_decision_receipt': [
    'event_id',
    'source_fingerprint',
    'operation_fingerprint',
  ],
};
const backupTableColumns = {
  ...backupV1TableColumns,
  'import_decision_receipt': [
    'event_id',
    'fingerprint_version',
    'source_fingerprint',
    'operation_fingerprint',
    'source_canonical',
    'operation_canonical',
    'original_target_id',
  ],
};
Map<String, List<String>> backupTableKeysForVersion(int version) =>
    switch (version) {
      1 => backupV1TableKeys,
      2 => backupTableKeys,
      _ => throw const DomainFailure(
        'UNSUPPORTED_FORMAT',
        'Unsupported backup version',
      ),
    };
Map<String, List<String>> backupTableColumnsForVersion(int version) =>
    switch (version) {
      1 => backupV1TableColumns,
      2 => backupTableColumns,
      _ => throw const DomainFailure(
        'UNSUPPORTED_FORMAT',
        'Unsupported backup version',
      ),
    };

final class BackupHeader {
  BackupHeader({
    required this.version,
    required Map<String, int> counts,
    this.backupVersion = 2,
  }) : counts = Map.unmodifiable(counts) {
    requireUuid(version.instanceId, 'instance_id');
    requireSafeInteger(version.activeEpoch, 'active_epoch', min: 0);
    requireSafeInteger(version.generation, 'generation', min: 0);
    if (counts.length != tableKeys.length ||
        !counts.keys.every(tableKeys.containsKey)) {
      throw const DomainFailure(
        'CORRUPT_BACKUP',
        'Backup table counts are incomplete',
      );
    }
    for (final count in counts.values) {
      requireSafeInteger(count, 'count', min: 0);
    }
  }
  final int backupVersion;
  Map<String, List<String>> get tableKeys =>
      backupTableKeysForVersion(backupVersion);
  Map<String, List<String>> get tableColumns =>
      backupTableColumnsForVersion(backupVersion);
  final DatabaseVersion version;
  final Map<String, int> counts;
  Map<String, Object?> toJson() => {
    'kind': 'header',
    'format': 'supplier-logical-backup',
    'backup_version': backupVersion,
    'schema_version': 2,
    'source_instance': version.instanceId,
    'source_epoch': version.activeEpoch,
    'generation': version.generation,
    'counts': counts,
  };
}

final class BackupEntry {
  factory BackupEntry(
    String table,
    Map<String, Object?> input, {
    int backupVersion = 2,
  }) {
    final keys = backupTableKeysForVersion(backupVersion);
    final columns = backupTableColumnsForVersion(backupVersion);
    final row = Map<String, Object?>.of(input);
    if (!keys.containsKey(table) || row.isEmpty) {
      throw const DomainFailure('CORRUPT_BACKUP', 'Invalid backup row');
    }
    exactKeys(row, columns[table]!);
    const numeric = {
      'active_epoch',
      'generation',
      'result_count',
      'schema_version',
      'fingerprint_version',
    };
    for (final key in row.keys) {
      if (numeric.contains(key)) {
        row[key] = requireSafeInteger(row[key], key, min: 0);
      } else if (row[key] is! String) {
        throw DomainFailure(
          'CORRUPT_BACKUP',
          'Expected text column',
          field: key,
        );
      }
    }
    if ((row.containsKey('schema_version') && row['schema_version'] != 2) ||
        (row.containsKey('fingerprint_version') &&
            row['fingerprint_version'] != 1)) {
      throw const DomainFailure(
        'UNSUPPORTED_FORMAT',
        'Unsupported receipt version',
      );
    }
    if (row.containsKey('instance_id')) {
      requireUuid(row['instance_id'], 'instance_id');
    }
    _checkEncodedBudget({'kind': 'row', 'table': table, 'row': row});
    if (table == 'local_settings') {
      try {
        jsonDecode(row['value_json']! as String);
      } on FormatException catch (error, stack) {
        throw DomainFailure(
          'CORRUPT_BACKUP',
          'Invalid preference JSON',
          field: 'value_json',
          cause: (error: error, stack: stack),
        );
      }
    }
    for (final key in keys[table]!) {
      if (row[key] is! String || (row[key]! as String).isEmpty) {
        throw const DomainFailure('CORRUPT_BACKUP', 'Missing row identity');
      }
    }
    if (table == 'revision') {
      if (row['canonical'] is! String) {
        throw const DomainFailure(
          'CORRUPT_BACKUP',
          'Missing revision envelope',
        );
      }
      final revision = RevisionEnvelope.fromCanonicalJson(
        row['canonical']! as String,
      );
      if (revision.revisionId != row['revision_id'] ||
          revision.entityId != row['entity_id'] ||
          revision.entityType != row['entity_type']) {
        throw const DomainFailure(
          'CORRUPT_BACKUP',
          'Revision identity differs from its canonical envelope',
        );
      }
    }
    if (table == 'import_decision_receipt') {
      validateBackupDecisionReceipt(row);
    }
    if (table == 'import_job' && row['state'] != 'committed') {
      throw const DomainFailure(
        'CORRUPT_BACKUP',
        'Unfinished jobs do not belong in a backup',
      );
    }
    return BackupEntry._(table, Map.unmodifiable(row));
  }
  const BackupEntry._(this.table, this.row);
  final String table;
  final Map<String, Object?> row;
}

final class BackupSummary {
  const BackupSummary(this.header, this.digest, this.bytes);
  final BackupHeader header;
  final String digest;
  final int bytes;
}

/// The line bound limits parser working memory, not whole backup size. A full
/// protocol envelope is at most 24000 UTF-16 units; this comfortably includes its
/// escaped JSON wrapper. Oversized preference/receipt rows fail without truncation.
const maxBackupLineBytes = 512 * 1024;

Stream<List<int>> encodeBackup(
  BackupHeader header,
  Stream<BackupEntry> entries,
) async* {
  final digest = _Digest();
  final hash = sha256.startChunkedConversion(digest);
  final counts = {for (final key in header.tableKeys.keys) key: 0};
  List<int> line(Map<String, Object?> value) {
    _checkEncodedBudget(value);
    final bytes = utf8.encode('${jsonEncode(value)}\n');
    if (bytes.length > maxBackupLineBytes) {
      throw const DomainFailure('BACKUP_ROW_LIMIT', 'Backup row is too large');
    }
    hash.add(bytes);
    return bytes;
  }

  yield line(header.toJson());
  await for (final entry in entries) {
    if (!counts.containsKey(entry.table)) {
      throw const DomainFailure(
        'CORRUPT_BACKUP',
        'Table not supported by backup version',
      );
    }
    counts[entry.table] = counts[entry.table]! + 1;
    if (counts[entry.table]! > header.counts[entry.table]!) {
      throw const DomainFailure('BACKUP_CHANGED', 'Snapshot row count differs');
    }
    yield line({'kind': 'row', 'table': entry.table, 'row': entry.row});
  }
  for (final table in counts.keys) {
    if (counts[table] != header.counts[table]) {
      throw const DomainFailure('BACKUP_CHANGED', 'Snapshot row count differs');
    }
  }
  hash.close();
  yield utf8.encode(
    '${jsonEncode({'kind': 'footer', 'sha256': digest.value.toString()})}\n',
  );
}

/// Fully consumes the source before returning success. Callbacks may populate an
/// isolated candidate, never the active database: footer/hash failure can happen
/// after the final row callback and must discard that candidate.
Future<BackupSummary> decodeBackup(
  InputSource source, {
  Future<void> Function(BackupHeader header)? onHeader,
  Future<void> Function(BackupEntry entry)? onEntry,
}) async {
  final digest = _Digest();
  final hash = sha256.startChunkedConversion(digest);
  BackupHeader? header;
  String? footer;
  var bytesRead = 0;
  var lineNumber = 0;
  final counts = <String, int>{};
  await for (final bytes in _lines(source)) {
    bytesRead += bytes.length;
    if (footer != null) {
      throw const DomainFailure('CORRUPT_BACKUP', 'Trailing data after footer');
    }
    final decoded = _parseRecord(bytes, ++lineNumber, bytesRead - bytes.length);
    if (header == null) {
      if (decoded['kind'] != 'header' ||
          decoded['format'] != 'supplier-logical-backup' ||
          ![1, 2].contains(decoded['backup_version']) ||
          decoded['schema_version'] != 2 ||
          decoded['counts'] is! Map<String, Object?>) {
        throw const DomainFailure(
          'UNSUPPORTED_FORMAT',
          'Unsupported backup header',
        );
      }
      final rawCounts = decoded['counts']! as Map<String, Object?>;
      header = _semantic<BackupHeader>(
        () => BackupHeader(
          backupVersion: decoded['backup_version']! as int,
          version: DatabaseVersion(
            instanceId: requireUuid(
              decoded['source_instance'],
              'source_instance',
            ),
            activeEpoch: requireSafeInteger(
              decoded['source_epoch'],
              'source_epoch',
              min: 0,
            ),
            generation: requireSafeInteger(
              decoded['generation'],
              'generation',
              min: 0,
            ),
          ),
          counts: rawCounts.map(
            (key, value) =>
                MapEntry(key, requireSafeInteger(value, key, min: 0)),
          ),
        ),
        lineNumber,
        bytesRead - bytes.length,
      );
      counts.addAll({for (final key in header.tableKeys.keys) key: 0});
      hash.add(bytes);
      await onHeader?.call(header);
    } else if (decoded['kind'] == 'row') {
      if (decoded['table'] is! String ||
          decoded['row'] is! Map<String, Object?>) {
        throw const DomainFailure('CORRUPT_BACKUP', 'Invalid backup row');
      }
      final entry = _semantic(
        () => BackupEntry(
          decoded['table']! as String,
          decoded['row']! as Map<String, Object?>,
          backupVersion: header!.backupVersion,
        ),
        lineNumber,
        bytesRead - bytes.length,
      );
      counts[entry.table] = counts[entry.table]! + 1;
      if (counts[entry.table]! > header.counts[entry.table]!) {
        throw const DomainFailure('CORRUPT_BACKUP', 'More rows than declared');
      }
      hash.add(bytes);
      await onEntry?.call(entry);
    } else if (decoded['kind'] == 'footer' && decoded['sha256'] is String) {
      hash.close();
      footer = decoded['sha256']! as String;
      if (footer != digest.value.toString()) {
        throw const DomainFailure('CORRUPT_BACKUP', 'Backup digest mismatch');
      }
    } else {
      throw const DomainFailure('CORRUPT_BACKUP', 'Unexpected backup record');
    }
  }
  if (header == null ||
      footer == null ||
      counts.keys.any((key) => counts[key] != header!.counts[key])) {
    throw const DomainFailure('CORRUPT_BACKUP', 'Incomplete backup');
  }
  return BackupSummary(header, footer, bytesRead);
}

Stream<List<int>> _lines(InputSource source) async* {
  final length = await source.length();
  requireSafeInteger(length, 'source_length', min: 0);
  var line = <int>[];
  for (var start = 0; start < length; start += 65536) {
    final end = (start + 65536).clamp(0, length);
    var read = 0;
    await for (final chunk in source.openRange(start, end)) {
      read += chunk.length;
      if (read > end - start) {
        throw const DomainFailure(
          'IO_FAILURE',
          'Input exceeded requested range',
        );
      }
      for (final byte in chunk) {
        if (line.length >= maxBackupLineBytes) {
          throw const DomainFailure(
            'BACKUP_ROW_LIMIT',
            'Backup row is too large',
          );
        }
        line.add(byte);
        if (byte == 10) {
          yield line;
          line = <int>[];
        }
      }
    }
    if (read != end - start) {
      throw const DomainFailure('IO_FAILURE', 'Input truncated');
    }
  }
  if (line.isNotEmpty) {
    throw const DomainFailure('CORRUPT_BACKUP', 'Truncated backup line');
  }
}

class _Digest implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

T _semantic<T>(T Function() parse, int line, int offset) {
  try {
    return parse();
  } catch (error, stack) {
    throw DomainFailure(
      'CORRUPT_BACKUP',
      'Invalid backup content at line $line',
      cause: (error: error, stack: stack, line: line, byteOffset: offset),
    );
  }
}

Map<String, Object?> _parseRecord(List<int> bytes, int line, int offset) {
  try {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is! Map<String, Object?>) {
      throw const FormatException('Expected object');
    }
    final fields = switch (value['kind']) {
      'header' => [
        'kind',
        'format',
        'backup_version',
        'schema_version',
        'source_instance',
        'source_epoch',
        'generation',
        'counts',
      ],
      'row' => ['kind', 'table', 'row'],
      'footer' => ['kind', 'sha256'],
      _ => throw const FormatException('Unknown record kind'),
    };
    exactKeys(value, fields);
    return value;
  } catch (error, stack) {
    // Parsing only: user callbacks and InputSource errors are outside this catch.
    throw DomainFailure(
      'CORRUPT_BACKUP',
      'Invalid backup record at line $line',
      cause: (error: error, stack: stack, line: line, byteOffset: offset),
    );
  }
}

/// Check UTF-8 JSON escaping costs before jsonDecode/jsonEncode or utf8.encode
/// can allocate a large temporary representation. Only bounded row/header maps
/// enter here; no whole-stream collection is performed.
void _checkEncodedBudget(Object? value) {
  var remaining = maxBackupLineBytes - 1; // newline
  void take(int count) {
    remaining -= count;
    if (remaining < 0) {
      throw const DomainFailure('BACKUP_ROW_LIMIT', 'Backup row is too large');
    }
  }

  void text(String value) {
    if (value.length > remaining) {
      throw const DomainFailure('BACKUP_ROW_LIMIT', 'Backup row is too large');
    }
    take(2);
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit == 34 || unit == 92) {
        take(2);
      } else if (unit < 32) {
        take(6);
      } else if (unit < 128) {
        take(1);
      } else if (unit < 2048) {
        take(2);
      } else if (unit >= 0xd800 &&
          unit <= 0xdbff &&
          i + 1 < value.length &&
          value.codeUnitAt(i + 1) >= 0xdc00 &&
          value.codeUnitAt(i + 1) <= 0xdfff) {
        take(4);
        i++;
      } else if (unit >= 0xd800 && unit <= 0xdfff) {
        take(6);
      } else {
        take(3);
      }
    }
  }

  void visit(Object? item) {
    if (item is String) {
      text(item);
    } else if (item is int) {
      take(item.toString().length);
    } else if (item is Map<String, Object?>) {
      take(2);
      var first = true;
      for (final entry in item.entries) {
        if (!first) take(1);
        first = false;
        text(entry.key);
        take(1);
        visit(entry.value);
      }
    } else {
      throw const DomainFailure(
        'CORRUPT_BACKUP',
        'Invalid encoded backup value',
      );
    }
  }

  visit(value);
}

/// Validates persisted intent without deriving any fields from current records.
void validateBackupDecisionReceipt(Map<String, Object?> row) {
  final decoded = <String, Map<String, Object?>>{};
  for (final prefix in ['source', 'operation']) {
    final encoded = row['${prefix}_canonical']! as String;
    final value = jsonDecode(encoded);
    if (value is! Map<String, Object?> ||
        canonicalJson(value) != encoded ||
        canonicalSha256(value) != row['${prefix}_fingerprint']) {
      throw const DomainFailure(
        'CORRUPT_BACKUP',
        'Decision canonical fingerprint mismatch',
      );
    }
    decoded[prefix] = value;
  }
  final source = decoded['source']!, operation = decoded['operation']!;
  exactKeys(source, [
    'version',
    'fields',
    'input_identity',
    'mapping_semantics',
    'batch_defaults',
    'capture_mode',
  ]);
  exactKeys(operation, [
    'version',
    'source_fingerprint',
    'intent',
    'original_bindings',
    'operations',
    'confirmed_quantity',
  ]);
  if (source['version'] != 1 ||
      operation['version'] != 1 ||
      !['standard', 'historical'].contains(source['capture_mode']) ||
      ![
        'modify',
        'newInquiry',
        'importHistorical',
      ].contains(operation['intent']) ||
      operation['source_fingerprint'] != row['source_fingerprint'] ||
      source['input_identity'] is! Map<String, Object?> ||
      source['mapping_semantics'] is! Map<String, Object?> ||
      source['batch_defaults'] is! Map<String, Object?> ||
      operation['original_bindings'] is! Map<String, Object?>) {
    throw const DomainFailure(
      'CORRUPT_BACKUP',
      'Invalid decision canonical structure',
    );
  }
  final quantity = requireSafeInteger(
    operation['confirmed_quantity'],
    'confirmed_quantity',
    min: 1,
  );
  if (operation['intent'] == 'modify' && quantity != 1) {
    throw const DomainFailure('CORRUPT_BACKUP', 'Modify quantity must be one');
  }
  if (operation['intent'] == 'importHistorical' &&
      (source['capture_mode'] != 'historical' ||
          row['original_target_id'] != '')) {
    throw const DomainFailure(
      'CORRUPT_BACKUP',
      'Historical import requires historical source mode and no original target',
    );
  }
  void cells(
    Object? value,
    String kindKey,
    List<String> kinds,
    String valueKind,
  ) {
    if (value is! Map<String, Object?>) {
      throw const DomainFailure('CORRUPT_BACKUP', 'Invalid decision field map');
    }
    for (final cell in value.values) {
      if (cell is! Map<String, Object?>) {
        throw const DomainFailure('CORRUPT_BACKUP', 'Invalid decision field');
      }
      exactKeys(cell, [kindKey, 'value']);
      if (!kinds.contains(cell[kindKey]) ||
          (cell[kindKey] == valueKind) != (cell['value'] != null)) {
        throw const DomainFailure(
          'CORRUPT_BACKUP',
          'Invalid decision field presence',
        );
      }
    }
  }

  cells(source['fields'], 'presence', ['missing', 'blank', 'value'], 'value');
  cells(operation['operations'], 'kind', ['keep', 'clear', 'set'], 'set');
}
