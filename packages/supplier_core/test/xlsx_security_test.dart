import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'excel_test.dart' show officeLike;

void main() {
  test('accepts ordinary ZIP comments but rejects ambiguous end records', () {
    final source = officeLike('<row><c r="A1"><v>1</v></c></row>');
    Uint8List withComment(List<int> comment) {
      final result = Uint8List.fromList([...source, ...comment]);
      ByteData.sublistView(
        result,
      ).setUint16(source.length - 2, comment.length, Endian.little);
      return result;
    }

    expect(readXlsx(withComment([65, 66, 67])).sheets, hasLength(1));
    final alternateEnd = Uint8List(22);
    ByteData.sublistView(alternateEnd).setUint32(0, 0x06054b50, Endian.little);
    expect(() => readXlsx(withComment(alternateEnd)), throwsFormatException);
  });

  test('rejects invalid and excessive sparse worksheet coordinates', () {
    for (final ref in ['A0', 'ZZZ1', 'A200001']) {
      expect(
        () => readXlsx(officeLike('<row><c r="$ref"><v>1</v></c></row>')),
        throwsFormatException,
        reason: ref,
      );
    }
  });

  test('rejects excessive declared expansion before reading entry content', () {
    final bytes = officeLike('<row><c r="A1"><v>1</v></c></row>');
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i + 46 < bytes.length; i++) {
      if (data.getUint32(i, Endian.little) == 0x02014b50) {
        data.setUint32(i + 24, maxExpandedBytes + 1, Endian.little);
        break;
      }
    }
    expect(() => readXlsx(bytes), throwsFormatException);
  });

  test('rejects forged small expanded size rather than trusting metadata', () {
    final bytes = officeLike('<row><c r="A1"><v>1</v></c></row>');
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i + 46 < bytes.length; i++) {
      if (data.getUint32(i, Endian.little) == 0x02014b50) {
        data.setUint32(i + 24, 1, Endian.little);
        break;
      }
    }
    expect(() => readXlsx(bytes), throwsFormatException);
  });

  test(
    'rejects Unix symbolic-link ZIP entries before their content is read',
    () {
      final bytes = officeLike('<row><c r="A1"><v>1</v></c></row>');
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i + 46 < bytes.length; i++) {
        if (data.getUint32(i, Endian.little) == 0x02014b50) {
          data.setUint16(i + 4, 3 << 8 | 20, Endian.little);
          data.setUint32(i + 38, 0xa1ff << 16, Endian.little);
          break;
        }
      }
      expect(() => readXlsx(bytes), throwsFormatException);
    },
  );

  test('retains CRC verification, including unused archive members', () {
    final bytes = officeLike('<row><c r="A1"><v>1</v></c></row>');
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i + 46 < bytes.length; i++) {
      if (data.getUint32(i, Endian.little) == 0x02014b50) {
        data.setUint32(i + 16, 0, Endian.little);
        final local = data.getUint32(i + 42, Endian.little);
        data.setUint32(local + 14, 0, Endian.little);
        break;
      }
    }
    expect(() => readXlsx(bytes), throwsFormatException);
  });

  test('normal stored ZIP and sparse blanks preserve row positions', () {
    final source = officeLike('<row><c r="C3"><v>12.30</v></c></row>');
    final archive = ZipDecoder().decodeBytes(source);
    for (final file in archive) {
      file.compress = false;
    }
    final rows = readXlsx(
      Uint8List.fromList(ZipEncoder().encode(archive)!),
    ).sheets.single.rows;
    expect(rows.length, 3);
    expect(rows[0], isEmpty);
    expect(rows[2][0].isBlank, isTrue);
    expect(rows[2][2].lexical, '12.30');
  });
}
