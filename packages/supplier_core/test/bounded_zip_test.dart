import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:supplier_core/src/exchange/bounded_zip.dart';
import 'package:test/test.dart';

class _Source implements InputSource {
  _Source(this.bytes);
  final List<int> bytes;
  @override
  String get displayName => 'test.xlsx';
  @override
  Future<int> length() async => bytes.length;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    for (var at = start; at < endExclusive; at += 17) {
      yield bytes.sublist(at, (at + 17).clamp(at, endExclusive));
    }
  }
}

Uint8List zip(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

int central(Uint8List bytes) =>
    ByteData.sublistView(bytes).getUint32(bytes.length - 6, Endian.little);
void main() {
  final corrupt = throwsA(
    isA<DomainFailure>().having((e) => e.code, 'code', 'CORRUPT_VOLUME'),
  );
  test('partial consumption does not certify unread entries', () async {
    final volume = await BoundedXlsxZip.read(
      _Source(
        zip({
          'one': [1],
          'two': [2],
        }),
      ),
    );
    await volume.expand().first;
    expect(volume.verified, isFalse);
  });
  test('local extra fields reject ZIP64 and malformed lengths', () async {
    for (final extra in [
      [1, 0, 0, 0],
      [42, 0, 10, 0],
      [42],
    ]) {
      await expectLater(
        BoundedXlsxZip.read(_Source(storedZip(localExtra: extra))),
        corrupt,
      );
    }
  });
  test('STORE entries support both data descriptor representations', () async {
    for (final signed in [true, false]) {
      final volume = await BoundedXlsxZip.read(
        _Source(storedZip(descriptor: true, signed: signed)),
      );
      expect((await volume.expand().single).bytes, [1, 2, 3]);
    }
  });
  test(
    'signature-valued CRC is not mistaken for a descriptor signature',
    () async {
      final volume = await BoundedXlsxZip.read(
        _Source(storedZip(descriptor: true, crcOverride: 0x08074b50)),
      );
      // Structure is valid; the deliberately forged CRC still fails readback.
      await expectLater(volume.expand().drain<void>(), corrupt);
    },
  );
  test(
    'bounded ZIP validates real entries and supports requested processing order',
    () async {
      final bytes = zip({
        'xl/worksheets/sheet1.xml': List.filled(10000, 65),
        'xl/sharedStrings.xml': [60, 62],
      });
      final volume = await BoundedXlsxZip.read(_Source(bytes));
      final result = await volume
          .expand(order: volume.names.toList().reversed.toList())
          .toList();
      expect(volume.verified, isTrue);
      expect(result.first.name, 'xl/sharedStrings.xml');
      expect(result.last.bytes, List.filled(10000, 65));
      await expectLater(volume.expand().drain<void>(), throwsStateError);
    },
  );
  test(
    'rejects compressed and declared expanded size before decoding',
    () async {
      final bytes = zip({'test': List.filled(2000, 65)});
      await expectLater(
        BoundedXlsxZip.read(
          _Source(bytes),
          limits: XlsxZipLimits(compressedBytes: bytes.length - 1),
        ),
        corrupt,
      );
      await expectLater(
        BoundedXlsxZip.read(
          _Source(bytes),
          limits: const XlsxZipLimits(expandedBytes: 100),
        ),
        corrupt,
      );
    },
  );
  test('forged declaration cannot hide actual expanded overflow', () async {
    final bytes = zip({'test': List.filled(2000, 65)});
    final data = ByteData.sublistView(bytes), directory = central(bytes);
    data.setUint32(directory + 24, 1, Endian.little);
    data.setUint32(22, 1, Endian.little);
    final volume = await BoundedXlsxZip.read(
      _Source(bytes),
      limits: const XlsxZipLimits(expandedBytes: 100),
    );
    await expectLater(volume.expand().drain<void>(), corrupt);
  });
  test('CRC mismatch is checked even for unrecognized resources', () async {
    final bytes = zip({
      'unused': [1, 2, 3],
    });
    final data = ByteData.sublistView(bytes), directory = central(bytes);
    data.setUint32(directory + 16, 42, Endian.little);
    data.setUint32(14, 42, Endian.little);
    final volume = await BoundedXlsxZip.read(_Source(bytes));
    await expectLater(volume.expand().drain<void>(), corrupt);
  });
  test(
    'EOCD underreported entries cannot bypass the actual count cap',
    () async {
      final bytes = zip({
        'one': [1],
        'two': [2],
      });
      final data = ByteData.sublistView(bytes);
      data.setUint16(bytes.length - 14, 1, Endian.little);
      data.setUint16(bytes.length - 12, 1, Endian.little);
      await expectLater(
        BoundedXlsxZip.read(
          _Source(bytes),
          limits: const XlsxZipLimits(entries: 1),
        ),
        corrupt,
      );
      await expectLater(BoundedXlsxZip.read(_Source(bytes)), corrupt);
    },
  );
  test(
    'unsupported encrypted and path-traversal entries fail before extraction',
    () async {
      await expectLater(
        BoundedXlsxZip.read(
          _Source(
            zip({
              '../test': [1],
            }),
          ),
        ),
        corrupt,
      );
      final bytes = zip({
        'test': [1],
      });
      final data = ByteData.sublistView(bytes);
      data.setUint16(central(bytes) + 8, 1, Endian.little);
      await expectLater(BoundedXlsxZip.read(_Source(bytes)), corrupt);
    },
  );
  test(
    'truncation and local/central identity disagreement are rejected',
    () async {
      final bytes = zip({
        'test': [1, 2, 3],
      });
      await expectLater(
        BoundedXlsxZip.read(_Source(bytes.sublist(0, bytes.length - 1))),
        corrupt,
      );
      bytes[30] = 88;
      await expectLater(BoundedXlsxZip.read(_Source(bytes)), corrupt);
    },
  );
}

Uint8List storedZip({
  List<int> localExtra = const [],
  bool descriptor = false,
  bool signed = false,
  int? crcOverride,
}) {
  final output = OutputStream();
  const payload = [1, 2, 3], name = [120];
  final crc = crcOverride ?? getCrc32(payload);
  output.writeUint32(0x04034b50);
  output.writeUint16(20);
  output.writeUint16(descriptor ? 8 : 0);
  output.writeUint16(0);
  output.writeUint32(0);
  output.writeUint32(descriptor ? 0 : crc);
  output.writeUint32(descriptor ? 0 : 3);
  output.writeUint32(descriptor ? 0 : 3);
  output.writeUint16(1);
  output.writeUint16(localExtra.length);
  output.writeBytes(name);
  output.writeBytes(localExtra);
  output.writeBytes(payload);
  if (descriptor) {
    if (signed) output.writeUint32(0x08074b50);
    output.writeUint32(crc);
    output.writeUint32(3);
    output.writeUint32(3);
  }
  final start = output.length;
  output.writeUint32(0x02014b50);
  output.writeUint16(20);
  output.writeUint16(20);
  output.writeUint16(descriptor ? 8 : 0);
  output.writeUint16(0);
  output.writeUint32(0);
  output.writeUint32(crc);
  output.writeUint32(3);
  output.writeUint32(3);
  output.writeUint16(1);
  output.writeUint16(0);
  output.writeUint16(0);
  output.writeUint16(0);
  output.writeUint16(0);
  output.writeUint32(0);
  output.writeUint32(0);
  output.writeBytes(name);
  final size = output.length - start;
  output.writeUint32(0x06054b50);
  output.writeUint16(0);
  output.writeUint16(0);
  output.writeUint16(1);
  output.writeUint16(1);
  output.writeUint32(size);
  output.writeUint32(start);
  output.writeUint16(0);
  return Uint8List.fromList(output.getBytes());
}
