import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import '../contracts.dart';
import '../data/database.dart' show sameVersion;
import 'bounded_zip.dart';
import 'bundle_manifest.dart';
import 'business_mapping.dart';
import 'projection_digest.dart';
import 'xlsx_reader.dart';
import 'xlsx_staging.dart';

/// An isolated, durable staging adapter. Append must enforce unique identities
/// in SQL. Validation must check the incoming graph's complete closure and
/// independently derive all business rows, including nulls, from that graph.
/// No method may write business authority or issue a commit authorization.
abstract interface class BundleStaging {
  DatabaseVersion get boundVersion;
  Future<void> begin(BundleManifest manifest);
  Future<void> append(
    String kind,
    BundleRow row, {
    required String path,
    required int rowNumber,
  });
  Future<void> verifyClosureAndProjection(
    BundleManifest manifest,
    BundleColumns columns,
  );
  Future<void> seal(String sourceDigest);
  Future<void> discard();
}

final class PreparedBundle {
  const PreparedBundle(this.manifest, this.sourceDigest, this.boundVersion);
  final BundleManifest manifest;
  final String sourceDigest;
  final DatabaseVersion boundVersion;
}

/// Bounded ZIP32 STORE directory. Payloads remain in the repeatable source;
/// only directory metadata and at most one XLSX volume enter memory. ZIP64 is
/// rejected explicitly by this adapter rather than silently narrowing offsets.
final class BundleArchive {
  BundleArchive._(this.source, this.entries);
  final InputSource source;
  final Map<String, BundleArchiveEntry> entries;
  static Future<BundleArchive> open(
    InputSource source,
    BundleBudget budget,
  ) async {
    budget.validate();
    final length = await source.length();
    if (length < 22 ||
        length > budget.compressedBytes ||
        length >= 0xffffffff) {
      bundleFailure('Outer ZIP size exceeds adapter/admission budget');
    }
    final tailStart = length > 65557 ? length - 65557 : 0;
    final tail = await bundleRange(source, tailStart, length);
    final data = ByteData.sublistView(tail);
    var end = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (data.getUint32(i, Endian.little) == 0x06054b50 &&
          i + 22 + data.getUint16(i + 20, Endian.little) == tail.length) {
        end = i;
        break;
      }
    }
    if (end < 0) bundleFailure('Missing outer ZIP end');
    int u16(int n) => data.getUint16(end + n, Endian.little);
    int u32(int n) => data.getUint32(end + n, Endian.little);
    final count = u16(10), central = u32(16), size = u32(12);
    if (u16(4) != 0 ||
        u16(6) != 0 ||
        u16(8) != count ||
        count == 65535 ||
        count > budget.volumes + 1 ||
        central + size != tailStart + end) {
      bundleFailure('Invalid outer ZIP directory');
    }
    var at = central;
    final entries = <String, BundleArchiveEntry>{};
    final ranges = <({int start, int end})>[];
    for (var i = 0; i < count; i++) {
      if (at + 46 > central + size) bundleFailure('Truncated outer directory');
      final header = ByteData.sublistView(
        await bundleRange(source, at, at + 46),
      );
      int h16(int n) => header.getUint16(n, Endian.little);
      int h32(int n) => header.getUint32(n, Endian.little);
      final names = h16(28),
          extra = h16(30),
          comment = h16(32),
          bytes = h32(20),
          local = h32(42);
      if (h32(0) != 0x02014b50 ||
          h16(8) & ~0x800 != 0 ||
          h16(10) != 0 ||
          bytes != h32(24) ||
          bytes == 0xffffffff ||
          extra != 0 ||
          h16(34) != 0 ||
          names < 1 ||
          names > 128 ||
          at + 46 + names + comment > central + size ||
          ((h32(38) >> 16) & 0xf000) == 0xa000) {
        bundleFailure('Unsupported outer ZIP entry');
      }
      final name = utf8.decode(
        await bundleRange(source, at + 46, at + 46 + names),
      );
      if (name != 'manifest.json' &&
          !RegExp(
            r'^(revisions|suppliers|contacts|products|quotations)-\d{6}\.xlsx$',
          ).hasMatch(name)) {
        bundleFailure('Unexpected outer ZIP path: $name');
      }
      if (entries.containsKey(name)) {
        bundleFailure('Duplicate outer ZIP path: $name');
      }
      if (bytes >
              (name == 'manifest.json'
                  ? budget.manifestBytes
                  : 8 * 1024 * 1024) ||
          local + 30 > central) {
        bundleFailure('Outer ZIP entry exceeds bounded limit');
      }
      final lh = ByteData.sublistView(
        await bundleRange(source, local, local + 30),
      );
      int l16(int n) => lh.getUint16(n, Endian.little);
      int l32(int n) => lh.getUint32(n, Endian.little);
      final start = local + 30 + names;
      if (l32(0) != 0x04034b50 ||
          l16(6) != h16(8) ||
          l16(8) != 0 ||
          l32(14) != h32(16) ||
          l32(18) != bytes ||
          l32(22) != bytes ||
          l16(26) != names ||
          l16(28) != 0 ||
          start + bytes > central ||
          utf8.decode(await bundleRange(source, local + 30, start)) != name) {
        bundleFailure('Outer local/central header mismatch');
      }
      entries[name] = BundleArchiveEntry(source, name, start, bytes, h32(16));
      ranges.add((start: local, end: start + bytes));
      at += 46 + names + comment;
    }
    if (at != central + size || !entries.containsKey('manifest.json')) {
      bundleFailure('Incomplete outer directory');
    }
    ranges.sort((a, b) => a.start.compareTo(b.start));
    var expected = 0;
    for (final range in ranges) {
      if (range.start != expected) {
        bundleFailure('Overlapping or hidden outer ZIP data');
      }
      expected = range.end;
    }
    if (expected != central) bundleFailure('Trailing hidden outer ZIP data');
    return BundleArchive._(source, Map.unmodifiable(entries));
  }

  Future<BundleManifest> manifest(BundleBudget budget) async {
    final entry = entries['manifest.json']!;
    await entry.verifyCrc();
    final manifest = BundleManifest.decode(
      await bundleRange(entry, 0, entry.bytes),
      budget,
    );
    for (final volume in manifest.volumes) {
      final entry = entries[volume.path];
      if (entry == null) {
        throw DomainFailure('MISSING_VOLUME', 'Missing volume: ${volume.path}');
      }
      if (entry.bytes != volume.compressedBytes) {
        bundleFailure('Volume length mismatch: ${volume.path}');
      }
    }
    if (entries.length != manifest.volumes.length + 1) {
      bundleFailure('Extra volume');
    }
    return manifest;
  }
}

final class BundleArchiveEntry implements InputSource {
  BundleArchiveEntry(
    this.source,
    this.displayName,
    this.start,
    this.bytes,
    this.crc,
  );
  final InputSource source;
  @override
  final String displayName;
  final int start, bytes, crc;
  @override
  Future<int> length() async => bytes;
  @override
  Stream<List<int>> openRange(int from, int to) {
    if (from < 0 || to < from || to > bytes) {
      throw RangeError('Invalid entry range');
    }
    return source.openRange(start + from, start + to);
  }

  Future<void> verifyCrc({Future<void> Function()? checkpoint}) async {
    var actual = 0;
    await for (final chunk in bundleChunks(this)) {
      actual = getCrc32(chunk, actual);
      await checkpoint?.call();
    }
    if (actual != crc) bundleFailure('Outer CRC mismatch: $displayName');
  }
}

Future<PreparedBundle> prepareBundle({
  required InputSource source,
  required BundleBudget budget,
  required BundleColumns columns,
  required BundleStaging staging,
  required Future<XlsxStaging> Function() createXlsxStaging,
  Future<void> Function()? checkpoint,
}) async {
  final binding = staging.boundVersion;
  try {
    final archive = await BundleArchive.open(source, budget);
    final sourceDigest = await bundleSha256(source, checkpoint);
    final manifest = await archive.manifest(budget);
    await staging.begin(manifest);
    final digest = BundleDigests(columns);
    var expanded = 0;
    for (final kind in bundleKinds) {
      digest.beginKind(kind);
      for (final volume in manifest.volumes.where((v) => v.kind == kind)) {
        await checkpoint?.call();
        final entry = archive.entries[volume.path]!;
        await entry.verifyCrc(checkpoint: checkpoint);
        if (await bundleSha256(entry, checkpoint) != volume.sha256) {
          bundleFailure('Volume SHA256 mismatch: ${volume.path}');
        }
        final zip = await BoundedXlsxZip.read(entry);
        var volumeExpanded = 0;
        await for (final part in zip.expand()) {
          volumeExpanded += part.bytes.length;
          expanded += part.bytes.length;
          if (expanded > budget.expandedBytes) {
            bundleFailure('Actual bundle expansion exceeds budget');
          }
          await checkpoint?.call();
        }
        if (!zip.verified || volumeExpanded != volume.expandedBytes) {
          bundleFailure('Actual volume expansion differs: ${volume.path}');
        }
        final parsed = await createXlsxStaging();
        try {
          final profile = await const BoundedXlsxReader().readVolume(
            entry,
            parsed,
            checkpoint: checkpoint,
          );
          if (profile.rows != volume.rowCount + 1) {
            bundleFailure('Volume row count mismatch: ${volume.path}');
          }
          var after = 0, seen = 0;
          while (true) {
            final page = await parsed.rowsPage(afterRow: after);
            if (page.isEmpty) break;
            for (final row in page) {
              if (row.row != ++seen) {
                bundleFailure(
                  'Sparse technical worksheet row: ${volume.path}:${row.row}',
                );
              }
              final values = <String?>[];
              var column = 0;
              while (true) {
                final cells = await parsed.cellsPage(
                  row.row,
                  afterColumn: column,
                );
                if (cells.isEmpty) break;
                for (final cell in cells) {
                  if (cell.column != ++column ||
                      column > columns.byKind[kind]!.length ||
                      ![
                        BusinessCellKind.text,
                        BusinessCellKind.blank,
                      ].contains(cell.cell.kind)) {
                    bundleFailure(
                      'Nontext or sparse technical cell: ${volume.path}:${cell.cell.coordinate}',
                    );
                  }
                  values.add(
                    cell.cell.kind == BusinessCellKind.blank
                        ? null
                        : cell.cell.lexical,
                  );
                }
              }
              if (values.length != columns.byKind[kind]!.length) {
                bundleFailure('Invalid row width: ${volume.path}:${row.row}');
              }
              if (row.row == 1) {
                if (jsonEncode(values) != jsonEncode(columns.byKind[kind])) {
                  bundleFailure('Fixed header mismatch: ${volume.path}');
                }
              } else {
                final record = BundleRow(values.first ?? '', values);
                digest.add(record);
                await staging.append(
                  kind,
                  record,
                  path: volume.path,
                  rowNumber: row.row,
                );
              }
            }
            after = page.last.row;
            await checkpoint?.call();
          }
        } finally {
          await parsed.close();
        }
      }
    }
    final actual = digest.finish();
    if (actual.revisions != manifest.revisionsDigest ||
        actual.business != manifest.businessDigest) {
      bundleFailure('Logical bundle digest mismatch');
    }
    await staging.verifyClosureAndProjection(manifest, columns);
    await checkpoint?.call();
    if (!sameVersion(binding, staging.boundVersion)) {
      bundleFailure('Staging validation version changed');
    }
    if (await bundleSha256(source, checkpoint) != sourceDigest) {
      bundleFailure('Source changed during bundle preparation');
    }
    await staging.seal(sourceDigest);
    return PreparedBundle(manifest, sourceDigest, binding);
  } catch (error, stack) {
    try {
      await staging.discard();
    } catch (cleanup) {
      throw DomainFailure(
        'BUNDLE_CLEANUP_FAILED',
        'Failed bundle staging could not be discarded',
        cause: (primary: error, cleanup: cleanup),
      );
    }
    Error.throwWithStackTrace(error, stack);
  }
}

Future<Uint8List> bundleRange(InputSource source, int start, int end) async {
  final result = Uint8List(end - start);
  var at = 0;
  await for (final chunk in source.openRange(start, end)) {
    if (chunk.length > result.length - at) {
      bundleFailure('Source exceeded requested range');
    }
    result.setRange(at, at + chunk.length, chunk);
    at += chunk.length;
  }
  if (at != result.length) bundleFailure('Truncated source range');
  return result;
}

Stream<List<int>> bundleChunks(InputSource source) async* {
  final length = await source.length();
  for (var at = 0; at < length; at += 65536) {
    yield await bundleRange(source, at, (at + 65536).clamp(0, length));
  }
}

Future<String> bundleSha256(
  InputSource source,
  Future<void> Function()? checkpoint,
) async {
  Stream<List<int>> checked() async* {
    await for (final chunk in bundleChunks(source)) {
      await checkpoint?.call();
      yield chunk;
    }
  }

  return (await sha256.bind(checked()).single).toString();
}
