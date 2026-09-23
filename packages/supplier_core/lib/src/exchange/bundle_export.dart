import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import '../application/backup_service.dart';
import '../contracts.dart';
import '../data/database.dart' show sameVersion;
import 'bundle_import.dart';
import 'bundle_manifest.dart';
import 'projection_digest.dart';
import 'xlsx_staging.dart';
import 'xlsx_writer.dart';

/// A private frozen database/snapshot. Implementations must never route page()
/// back to the active database. assertFrozen checks this snapshot's identity,
/// not whether the user has made later edits in the active database.
abstract interface class BundleSnapshot {
  DatabaseVersion get version;
  Future<void> assertFrozen();
  Stream<BundleRow> page(String kind, {String? afterKey, required int limit});
}

/// Produces one bounded XLSX at a time, persists it before making the next,
/// streams the outer STORE ZIP, then parses and validates the entire private
/// result before copying it into the caller's publishable target.
Future<BundleManifest> exportBundle({
  required BundleSnapshot snapshot,
  required BundleColumns columns,
  required BundleBudget budget,
  required String bundleId,
  required String exportedAt,
  required String exporterVersion,
  required Future<BackupArtifact> Function() createArtifact,
  required Future<XlsxStaging> Function() createXlsxStaging,
  required Future<BundleStaging> Function(DatabaseVersion version)
  createBundleStaging,
  required OutputTarget target,
  int rowsPerVolume = 5000,
  Future<void> Function()? checkpoint,
}) async {
  budget.validate();
  if (rowsPerVolume < 1 || rowsPerVolume > 5000) {
    throw ArgumentError.value(rowsPerVolume);
  }
  final artifacts = <BackupArtifact>[];
  final files = <({String path, InputSource source})>[];
  final volumes = <BundleVolume>[];
  final digest = BundleDigests(columns);
  var published = false;
  Object? primary;
  StackTrace? primaryStack;
  final cleanup = <({String stage, Object error, StackTrace stack})>[];
  try {
    final version = snapshot.version;
    Future<void> check() async {
      await checkpoint?.call();
      await snapshot.assertFrozen();
      if (!sameVersion(version, snapshot.version)) {
        bundleFailure('Snapshot version changed');
      }
    }

    await check();
    var compressed = 0, expanded = 0;
    for (final kind in bundleKinds) {
      digest.beginKind(kind);
      String? cursor;
      var index = 0;
      while (true) {
        await check();
        var limit = rowsPerVolume;
        late BoundedXlsxVolume volume;
        String? last;
        while (true) {
          final validation = await createXlsxStaging();
          Object? encodingFailure;
          StackTrace? encodingStack;
          try {
            var count = 0;
            Stream<List<String?>> rows() async* {
              await for (final row in snapshot.page(
                kind,
                afterKey: cursor,
                limit: limit,
              )) {
                if (++count > limit ||
                    (last != null && row.key.compareTo(last!) <= 0) ||
                    (cursor != null && row.key.compareTo(cursor) <= 0)) {
                  bundleFailure('Snapshot violated bounded keyset ordering');
                }
                last = row.key;
                yield row.cells;
              }
            }

            last = null;
            volume = await const BoundedXlsxWriter().encodeVolume(
              rows: rows(),
              headers: columns.byKind[kind]!,
              validation: validation,
              policy: XlsxExportPolicy.syncVolume(maxDataRows: limit),
              checkpoint: check,
            );
            break;
          } catch (error, stack) {
            encodingFailure = error;
            encodingStack = stack;
            if (error is! DomainFailure ||
                error.code != 'XLSX_VOLUME_LIMIT' ||
                limit == 1) {
              rethrow;
            }
            limit = (limit ~/ 2).clamp(1, 5000);
          } finally {
            try {
              await validation.close();
            } catch (error, stack) {
              throw DomainFailure(
                'BUNDLE_CLEANUP_FAILED',
                'Volume validation cleanup failed',
                cause: (
                  primary: encodingFailure,
                  primaryStack: encodingStack,
                  cleanup: error,
                  cleanupStack: stack,
                ),
              );
            }
          }
        }
        if (volume.dataRows == 0 && index > 0) break;
        if (volumes.length >= budget.volumes) {
          bundleFailure('Export volume budget exceeded');
        }
        final descriptor = BundleVolume(
          kind: kind,
          index: ++index,
          rowCount: volume.dataRows,
          sha256: volume.sha256Hex,
          compressedBytes: volume.byteLength,
          expandedBytes: volume.expandedBytes,
        );
        compressed += descriptor.compressedBytes;
        expanded += descriptor.expandedBytes;
        if (compressed > budget.compressedBytes ||
            expanded > budget.expandedBytes) {
          bundleFailure('Export exceeds admission space budget');
        }
        final artifact = await createArtifact();
        artifacts.add(artifact);
        await artifact.output.write(bundleChunks(volume));
        await artifact.output.publish();
        files.add((path: descriptor.path, source: artifact.source));
        volumes.add(descriptor);
        var reread = 0;
        await for (final row in snapshot.page(
          kind,
          afterKey: cursor,
          limit: volume.dataRows == 0 ? 1 : volume.dataRows,
        )) {
          if (++reread > volume.dataRows) {
            bundleFailure('Snapshot page changed after encoding');
          }
          digest.add(row);
        }
        if (reread != volume.dataRows) {
          bundleFailure('Snapshot page changed after encoding');
        }
        if (digest.counts['revisions']! > budget.revisions) {
          bundleFailure('Revision admission budget exceeded');
        }
        cursor = last;
        if (volume.dataRows < limit) break;
      }
    }
    final hashes = digest.finish();
    final manifest = BundleManifest(
      bundleId: bundleId,
      exportedAt: exportedAt,
      exporterVersion: exporterVersion,
      revisionCount: digest.counts['revisions']!,
      entityCounts: {
        for (final kind in bundleKinds.skip(1)) kind: digest.counts[kind]!,
      },
      revisionsDigest: hashes.revisions,
      businessDigest: hashes.business,
      volumes: volumes,
      budget: budget,
    );
    final outer = await createArtifact();
    artifacts.add(outer);
    final manifestSource = _ManifestSource(utf8.encode(manifest.encode()));
    await outer.output.write(
      encodeBundleStore(
        [(path: 'manifest.json', source: manifestSource), ...files],
        budget,
        checkpoint: check,
      ),
    );
    await outer.output.publish();
    await check();
    final verifier = await createBundleStaging(version);
    await prepareBundle(
      source: outer.source,
      budget: budget,
      columns: columns,
      staging: verifier,
      createXlsxStaging: createXlsxStaging,
      checkpoint: check,
    );
    await verifier.discard();
    await check();
    await target.write(bundleChunks(outer.source));
    await target.publish();
    published = true;
    return manifest;
  } catch (error, stack) {
    primary = error;
    primaryStack = stack;
    if (!published) {
      try {
        await target.abort();
      } catch (error, stack) {
        cleanup.add((stage: 'abort', error: error, stack: stack));
      }
    }
    Error.throwWithStackTrace(error, stack);
  } finally {
    for (final artifact in artifacts.reversed) {
      try {
        await artifact.dispose();
      } catch (error, stack) {
        cleanup.add((stage: 'artifact.dispose', error: error, stack: stack));
      }
    }
    if (cleanup.isNotEmpty) {
      throw DomainFailure(
        'BUNDLE_CLEANUP_FAILED',
        'Private bundle artifact cleanup failed',
        cause: (
          primary: primary,
          primaryStack: primaryStack,
          cleanup: cleanup,
          published: published,
        ),
      );
    }
  }
}

/// Streaming ZIP32 STORE writer. CRC is computed from a repeatable private
/// artifact before writing its local header; bytes are checked again by the
/// mandatory post-write import verification before external publication.
Stream<List<int>> encodeBundleStore(
  List<({String path, InputSource source})> files,
  BundleBudget budget, {
  Future<void> Function()? checkpoint,
}) async* {
  budget.validate();
  if (files.length > budget.volumes + 1) {
    bundleFailure('Too many outer entries');
  }
  final directory = <Uint8List>[];
  final names = <String>{};
  var offset = 0;
  for (final file in files) {
    final name = utf8.encode(file.path), length = await file.source.length();
    if (!names.add(file.path) ||
        name.length > 128 ||
        length >= 0xffffffff ||
        length < 0) {
      bundleFailure('Invalid outer export entry');
    }
    var crc = 0;
    await for (final chunk in bundleChunks(file.source)) {
      crc = getCrc32(chunk, crc);
      await checkpoint?.call();
    }
    final local = Uint8List(30 + name.length), ld = ByteData.sublistView(local);
    ld.setUint32(0, 0x04034b50, Endian.little);
    ld.setUint16(4, 20, Endian.little);
    ld.setUint16(6, 0x800, Endian.little);
    ld.setUint32(14, crc, Endian.little);
    ld.setUint32(18, length, Endian.little);
    ld.setUint32(22, length, Endian.little);
    ld.setUint16(26, name.length, Endian.little);
    local.setRange(30, local.length, name);
    final central = Uint8List(46 + name.length),
        cd = ByteData.sublistView(central);
    cd.setUint32(0, 0x02014b50, Endian.little);
    cd.setUint16(4, 20, Endian.little);
    cd.setUint16(6, 20, Endian.little);
    cd.setUint16(8, 0x800, Endian.little);
    cd.setUint32(16, crc, Endian.little);
    cd.setUint32(20, length, Endian.little);
    cd.setUint32(24, length, Endian.little);
    cd.setUint16(28, name.length, Endian.little);
    cd.setUint32(42, offset, Endian.little);
    central.setRange(46, central.length, name);
    directory.add(central);
    offset += local.length + length;
    if (offset >= 0xffffffff || offset > budget.compressedBytes) {
      bundleFailure('Outer ZIP exceeds adapter/admission budget');
    }
    yield local;
    await for (final chunk in bundleChunks(file.source)) {
      yield chunk;
      await checkpoint?.call();
    }
  }
  final start = offset;
  for (final record in directory) {
    offset += record.length;
    yield record;
  }
  if (offset + 22 >= 0xffffffff || offset + 22 > budget.compressedBytes) {
    bundleFailure('Outer ZIP directory exceeds budget');
  }
  final end = Uint8List(22), ed = ByteData.sublistView(end);
  ed.setUint32(0, 0x06054b50, Endian.little);
  ed.setUint16(8, files.length, Endian.little);
  ed.setUint16(10, files.length, Endian.little);
  ed.setUint32(12, offset - start, Endian.little);
  ed.setUint32(16, start, Endian.little);
  yield end;
}

final class _ManifestSource implements InputSource {
  _ManifestSource(this.bytes);
  final List<int> bytes;
  @override
  String get displayName => 'manifest.json';
  @override
  Future<int> length() async => bytes.length;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    yield bytes.sublist(start, endExclusive);
  }
}
