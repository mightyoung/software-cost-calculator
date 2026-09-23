import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../contracts.dart';

/// Limits apply to one XLSX volume, never to an entire outer exchange bundle.
final class XlsxZipLimits {
  const XlsxZipLimits({
    this.compressedBytes = 8 * 1024 * 1024,
    this.expandedBytes = 32 * 1024 * 1024,
    this.entries = 2048,
  });
  final int compressedBytes, expandedBytes, entries;
}

/// A bounded compressed volume and small entry directory. Entry expansion is
/// sequential and counted cumulatively; callers must not retain every payload.
final class BoundedXlsxZip {
  BoundedXlsxZip._(this._bytes, this._entries, this.limits);
  final Uint8List _bytes;
  final List<_ZipEntry> _entries;
  final XlsxZipLimits limits;
  bool _consumed = false;
  bool _verified = false;
  bool get verified => _verified;

  static Future<BoundedXlsxZip> read(
    InputSource source, {
    XlsxZipLimits limits = const XlsxZipLimits(),
  }) async {
    if (limits.compressedBytes < 22 ||
        limits.expandedBytes < 0 ||
        limits.entries < 1) {
      throw ArgumentError('Invalid XLSX volume limits');
    }
    final size = await source.length();
    if (size < 22 || size > limits.compressedBytes) {
      _bad('compressed size exceeds volume limit');
    }
    final bytes = Uint8List(size);
    var offset = 0;
    await for (final chunk in source.openRange(0, size)) {
      if (chunk.length > size - offset) _bad('input exceeds declared length');
      bytes.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    if (offset != size) _bad('input is truncated');
    final data = ByteData.sublistView(bytes);
    int u16(int at) => data.getUint16(at, Endian.little);
    int u32(int at) => data.getUint32(at, Endian.little);
    void validateExtra(int start, int end) {
      for (var at = start; at < end;) {
        if (at + 4 > end) _bad('truncated extra field');
        if (u16(at) == 1) _bad('ZIP64 is not an XLSX volume');
        at += 4 + u16(at + 2);
        if (at > end) _bad('invalid extra field length');
      }
    }

    var end = -1;
    for (var at = size - 22; at >= 0 && at >= size - 65557; at--) {
      if (u32(at) == 0x06054b50 && at + 22 + u16(at + 20) == size) {
        end = at;
        break;
      }
    }
    if (end < 0) _bad('missing ZIP end record');
    final count = u16(end + 10),
        centralSize = u32(end + 12),
        centralStart = u32(end + 16);
    if (u16(end + 4) != 0 ||
        u16(end + 6) != 0 ||
        u16(end + 8) != count ||
        count == 65535 ||
        count > limits.entries ||
        centralStart + centralSize != end) {
      _bad('unsupported multi-disk/ZIP64 or invalid directory bounds');
    }
    final entries = <_ZipEntry>[];
    final names = <String>{};
    var at = centralStart, declared = 0;
    while (at < end) {
      if (entries.length >= limits.entries ||
          at + 46 > end ||
          u32(at) != 0x02014b50) {
        _bad('invalid or oversized central directory');
      }
      final flags = u16(at + 8), method = u16(at + 10), crc = u32(at + 16);
      final compressed = u32(at + 20), expanded = u32(at + 24);
      final nameLength = u16(at + 28),
          extraLength = u16(at + 30),
          commentLength = u16(at + 32);
      final next = at + 46 + nameLength + extraLength + commentLength;
      final local = u32(at + 42);
      if (next > end ||
          u16(at + 34) != 0 ||
          compressed == 0xffffffff ||
          expanded == 0xffffffff ||
          flags & ~0x080e != 0 ||
          ((u32(at + 38) >> 16) & 0xf000) == 0xa000 ||
          (method != 0 && method != 8)) {
        _bad('unsupported entry flags, compression or bounds');
      }
      String name;
      try {
        name = utf8.decode(bytes.sublist(at + 46, at + 46 + nameLength));
      } on FormatException {
        _bad('entry name is not UTF-8');
      }
      if (name.isEmpty ||
          name.startsWith('/') ||
          name.contains('\\') ||
          name.contains(':') ||
          name.contains('\u0000') ||
          name.split('/').contains('..') ||
          name.split('/').contains('.') ||
          !names.add(name)) {
        _bad('unsafe or duplicate entry name');
      }
      validateExtra(at + 46 + nameLength, at + 46 + nameLength + extraLength);
      declared += expanded;
      if (declared > limits.expandedBytes ||
          local + 30 > centralStart ||
          u32(local) != 0x04034b50) {
        _bad('expanded limit or invalid local header');
      }
      final localNameLength = u16(local + 26), localExtra = u16(local + 28);
      final start = local + 30 + localNameLength + localExtra;
      if (start + compressed > centralStart ||
          flags != u16(local + 6) ||
          method != u16(local + 8) ||
          localNameLength != nameLength) {
        _bad('local/central header mismatch');
      }
      validateExtra(local + 30 + localNameLength, start);
      for (var i = 0; i < nameLength; i++) {
        if (bytes[local + 30 + i] != bytes[at + 46 + i]) {
          _bad('entry name mismatch');
        }
      }
      if (flags & 8 == 0 &&
          (u32(local + 14) != crc ||
              u32(local + 18) != compressed ||
              u32(local + 22) != expanded)) {
        _bad('local size or checksum mismatch');
      }
      var finish = start + compressed;
      if (flags & 8 != 0) {
        bool descriptorAt(int position) =>
            position + 12 <= centralStart &&
            u32(position) == crc &&
            u32(position + 4) == compressed &&
            u32(position + 8) == expanded;
        if (descriptorAt(finish)) {
          finish += 12;
        } else if (finish + 16 <= centralStart &&
            u32(finish) == 0x08074b50 &&
            descriptorAt(finish + 4)) {
          finish += 16;
        } else {
          _bad('data descriptor mismatch');
        }
      }
      entries.add(
        _ZipEntry(
          name,
          local,
          start,
          finish,
          compressed,
          expanded,
          method,
          crc,
        ),
      );
      at = next;
    }
    if (entries.length != count || at != end) {
      _bad('directory entry count mismatch');
    }
    final ranges = entries.toList()..sort((a, b) => a.local.compareTo(b.local));
    for (var i = 1; i < ranges.length; i++) {
      if (ranges[i].local < ranges[i - 1].finish) {
        _bad('overlapping ZIP entries');
      }
    }
    return BoundedXlsxZip._(bytes, List.unmodifiable(entries), limits);
  }

  Iterable<String> get names => _entries.map((entry) => entry.name);

  /// Fully consume successfully before accepting the volume. Only then has
  /// every entry been expanded and CRC-checked, including unknown resources.
  /// Requested processing order permits shared strings before worksheets.
  Stream<({String name, List<int> bytes})> expand({
    List<String>? order,
  }) async* {
    if (_consumed) throw StateError('Volume expansion is single-use');
    _consumed = true;
    final byName = {for (final entry in _entries) entry.name: entry};
    final selected = order ?? names.toList();
    if (selected.length != byName.length ||
        selected.toSet().length != byName.length ||
        selected.any((name) => !byName.containsKey(name))) {
      throw ArgumentError(
        'Expansion order must contain every entry exactly once',
      );
    }
    var expanded = 0;
    for (final name in selected) {
      final entry = byName[name]!;
      final output = _LimitedOutput(limits.expandedBytes - expanded);
      final input = InputStream(
        _bytes,
        start: entry.start,
        length: entry.compressed,
      );
      try {
        if (entry.method == 0) {
          output.writeInputStream(input);
        } else {
          Inflate.stream(input, output);
        }
      } on DomainFailure {
        rethrow;
      } catch (error, stack) {
        throw DomainFailure(
          'CORRUPT_VOLUME',
          'Invalid compressed entry: $name',
          cause: (error: error, stack: stack),
        );
      }
      final content = output.getBytes();
      if (content.length != entry.expanded || getCrc32(content) != entry.crc) {
        _bad('expanded size or CRC mismatch: $name');
      }
      expanded += content.length;
      yield (name: name, bytes: content);
    }
    _verified = true;
  }
}

final class _ZipEntry {
  const _ZipEntry(
    this.name,
    this.local,
    this.start,
    this.finish,
    this.compressed,
    this.expanded,
    this.method,
    this.crc,
  );
  final String name;
  final int local, start, finish, compressed, expanded, method, crc;
}

class _LimitedOutput extends OutputStream {
  _LimitedOutput(this.limit);
  final int limit;
  void _check(int count) {
    if (count < 0 || count > limit - length) {
      _bad('actual expanded byte limit exceeded');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, [int? len]) {
    _check(len ?? bytes.length);
    super.writeBytes(bytes, len);
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    _check(stream.length);
    super.writeInputStream(stream);
  }
}

Never _bad(String reason) => throw DomainFailure('CORRUPT_VOLUME', reason);
