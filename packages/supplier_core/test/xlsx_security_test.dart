import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'excel_test.dart' show officeLike;

Uint8List _referencedSheets(List<String> targets) {
  final parts = {
    'xl/workbook.xml':
        '<workbook xmlns:r="r"><workbookPr date1904="1"/><sheets>'
        '${[for (var i = 0; i < targets.length; i++) '<sheet name="S$i" r:id="r$i"/>'].join()}'
        '</sheets></workbook>',
    'xl/_rels/workbook.xml.rels':
        '<Relationships>'
        '${[for (var i = 0; i < targets.length; i++) '<Relationship Id="r$i" Target="${targets[i]}"/>'].join()}'
        '</Relationships>',
    for (final target in targets)
      (target.startsWith('/') ? target.substring(1) : 'xl/$target'):
          '<worksheet><!--${'x' * 65536}--><sheetData/></worksheet>',
  };
  final archive = Archive();
  for (final part in parts.entries) {
    final bytes = utf8.encode(part.value);
    archive.addFile(ArchiveFile(part.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  test('rejects repeated worksheet targets before reparsing empty XML', () {
    for (final targets in [
      ['worksheets/s.xml', 'worksheets/s.xml'],
      ['worksheets/s.xml', '/xl/worksheets/s.xml'],
    ]) {
      final bytes = _referencedSheets(targets);
      expect(bytes.length, lessThan(10000));
      expect(() => readXlsx(bytes), throwsFormatException);
    }
  });

  test('rejects excessive empty sheet declarations within ZIP limits', () {
    final bytes = _referencedSheets(
      List.filled(maxZipEntries + 1, 'worksheets/s.xml'),
    );
    expect(bytes.length, lessThan(maxXlsxBytes));
    expect(() => readXlsx(bytes), throwsFormatException);
  });

  test('distinct empty worksheet parts retain order and date system', () {
    final book = readXlsx(
      _referencedSheets(['worksheets/s.xml', '/xl/worksheets/t.xml']),
    );
    expect(book.date1904, isTrue);
    expect(book.sheets.map((s) => s.name), ['S0', 'S1']);
    expect(book.sheets.every((s) => s.rows.isEmpty), isTrue);
  });

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
