import 'dart:io' as io;
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Data-only ZIP decoding. Never asks ArchiveFile/ZipFile for `content`:
/// archive 3.x inflates that getter without an actual-output size limit.
Map<String, Uint8List> readBoundedZip(
  Uint8List bytes, {
  required int maxEntries,
  required int maxExpandedBytes,
}) {
  _checkDirectory(bytes, maxEntries);
  final directory = ZipDirectory.read(InputStream(bytes));
  final result = <String, Uint8List>{};
  var declared = 0;
  for (final header in directory.fileHeaders) {
    final file = header.file!;
    final size = header.uncompressedSize!;
    final mode = (header.externalFileAttributes! >> 16) & 0xf000;
    if (size < 0 ||
        (declared += size) > maxExpandedBytes ||
        file.flags & 1 != 0 ||
        (file.compressionMethod != 0 && file.compressionMethod != 8) ||
        (header.versionMadeBy >> 8 == 3 &&
            mode != 0 &&
            mode != 0x8000 &&
            mode != 0x4000) ||
        file.filename.isEmpty ||
        result.containsKey(file.filename)) {
      throw const FormatException('不支持的 ZIP 结构或解压后过大');
    }
    // Reserve names now, including empty entries; duplicate parts are ambiguous.
    result[file.filename] = Uint8List(0);
  }
  for (final header in directory.fileHeaders) {
    final file = header.file!;
    final size = header.uncompressedSize!;
    final raw = file.rawContent!.toUint8List();
    final output = _BoundedOutput(size);
    if (file.compressionMethod == 0) {
      output.add(raw);
    } else {
      final decoder = io.ZLibDecoder(raw: true).startChunkedConversion(output);
      // Bound work passed to native inflate at once, including forged sizes.
      for (var offset = 0; offset < raw.length; offset += 1024) {
        final end = offset + 1024 < raw.length ? offset + 1024 : raw.length;
        decoder.add(Uint8List.sublistView(raw, offset, end));
      }
      decoder.close();
    }
    final content = output.takeBytes();
    if (content.length != size || getCrc32(content) != header.crc32) {
      throw const FormatException('ZIP 长度或校验值不符');
    }
    result[file.filename] = content;
  }
  return result;
}

class _BoundedOutput implements Sink<List<int>> {
  _BoundedOutput(this.limit);
  final int limit;
  final _bytes = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (data.length > limit - _bytes.length) {
      throw const FormatException('文件解压后过大或长度不符');
    }
    _bytes.add(data);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _bytes.takeBytes();
}

/// Count central headers before archive's parser allocates per-entry objects.
/// ZIP64 is retained for small files produced by ZIP64-capable office tools.
void _checkDirectory(Uint8List bytes, int limit) {
  final data = ByteData.sublistView(bytes);
  Never bad() => throw const FormatException('ZIP 目录无效或条目过多');
  int u16(int p) => data.getUint16(p, Endian.little);
  int u32(int p) => data.getUint32(p, Endian.little);
  int u64(int p) => data.getUint64(p, Endian.little);
  var end = -1;
  final first = bytes.length > 65557 ? bytes.length - 65557 : 0;
  for (var p = bytes.length - 22; p >= first; p--) {
    if (u32(p) == 0x06054b50 && p + 22 + u16(p + 20) == bytes.length) {
      end = p;
      break;
    }
  }
  if (end < 0 || u16(end + 4) != 0 || u16(end + 6) != 0) bad();
  // archive 3.x finds the last signature without checking comment length.
  // Reject ambiguous comments so its directory is the one checked here.
  for (var p = end + 1; p < bytes.length - 4; p++) {
    if (u32(p) == 0x06054b50) bad();
  }
  var count = u16(end + 10), size = u32(end + 12), offset = u32(end + 16);
  if (count == 0xffff || size == 0xffffffff || offset == 0xffffffff) {
    final locator = end - 20;
    if (locator < 0 ||
        u32(locator) != 0x07064b50 ||
        u32(locator + 4) != 0 ||
        u32(locator + 16) != 1)
      bad();
    final z = u64(locator + 8);
    if (z < 0 ||
        z > locator - 56 ||
        u32(z) != 0x06064b50 ||
        u32(z + 16) != 0 ||
        u32(z + 20) != 0)
      bad();
    count = u64(z + 32);
    size = u64(z + 40);
    offset = u64(z + 48);
    if (u64(z + 24) != count) bad();
  } else if (u16(end + 8) != count) {
    bad();
  }
  if (count < 0 ||
      count > limit ||
      size < 0 ||
      offset < 0 ||
      offset > end ||
      size > end - offset)
    bad();
  final stop = offset + size;
  var seen = 0;
  for (var p = offset; p < stop;) {
    if (++seen > limit || p + 46 > stop || u32(p) != 0x02014b50) bad();
    final next = p + 46 + u16(p + 28) + u16(p + 30) + u16(p + 32);
    if (next > stop) bad();
    p = next;
  }
  if (seen != count) bad();
}
