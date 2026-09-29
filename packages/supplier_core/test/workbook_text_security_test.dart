import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

Uint8List sharedWorkbook(String shared, int references) {
  final files = {
    'xl/workbook.xml':
        '<workbook xmlns:r="r"><sheets><sheet name="Shared" r:id="s"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels':
        '<Relationships><Relationship Id="s" Target="worksheets/s.xml"/></Relationships>',
    'xl/sharedStrings.xml': '<sst><si><t>$shared</t></si></sst>',
    'xl/worksheets/s.xml':
        '<worksheet><sheetData>${[for (var i = 1; i <= references; i++) '<row><c r="A$i" t="s"><v>0</v></c></row>'].join()}</sheetData></worksheet>',
  };
  final archive = Archive();
  for (final entry in files.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  test('rejects shared-string amplification within all XLSX limits', () {
    final bytes = sharedWorkbook('x' * 32767, 33);
    expect(bytes.length, lessThan(10000));
    final book = readXlsx(bytes);
    expect(book.sheets.single.rows, hasLength(33));
    expect(() {
      workbookText(book);
    }, throwsFormatException);
  });

  test('rejects one oversized cell before assembling workbook text', () {
    final book = XWorkbook([
      XSheet('S', [
        [XCell('A1', CellKind.text, 'x' * (1024 * 1024))],
      ]),
    ], date1904: false);
    expect(() {
      workbookText(book);
    }, throwsFormatException);
  });

  test('counts headings, separators and newlines across sheets exactly', () {
    final book = XWorkbook([
      XSheet('一', [
        [
          const XCell('A1', CellKind.text, ' a '),
          const XCell('B1', CellKind.blank, ''),
          const XCell('C1', CellKind.number, '1.20e1', formula: true),
        ],
        [],
        [const XCell('A3', CellKind.text, ' \t\n ')],
      ]),
      XSheet('二', [
        [const XCell('A1', CellKind.text, '结果', formula: true)],
      ]),
    ], date1904: false);
    const expected = '【一】\na |  | 12\n【二】\n结果';
    expect(workbookText(book, maxChars: expected.length), expected);
    expect(() {
      workbookText(book, maxChars: expected.length - 1);
    }, throwsFormatException);
  });

  test('empty workbook and sheets retain their original format', () {
    expect(workbookText(XWorkbook([], date1904: false), maxChars: 0), '');
    final book = XWorkbook([XSheet('', []), XSheet('S', [])], date1904: false);
    expect(workbookText(book, maxChars: 6), '【】\n【S】');
    expect(() {
      workbookText(book, maxChars: 5);
    }, throwsFormatException);
    expect(() {
      workbookText(book, maxChars: -1);
    }, throwsArgumentError);
  });

  test('checks oversized heading and cell with a caller budget', () {
    for (final book in [
      XWorkbook([XSheet('name-too-long', [])], date1904: false),
      XWorkbook([
        XSheet('S', [
          [const XCell('A1', CellKind.text, 'too-long')],
        ]),
      ], date1904: false),
    ]) {
      expect(() {
        workbookText(book, maxChars: 8);
      }, throwsFormatException);
    }
  });

  test(
    'default limit accepts its exact boundary but not one extra character',
    () {
      XWorkbook book(int n) => XWorkbook([
        XSheet('S', [
          [XCell('A1', CellKind.text, 'x' * n)],
        ]),
      ], date1904: false);
      expect(workbookText(book(1024 * 1024 - 4)).length, 1024 * 1024);
      expect(() {
        workbookText(book(1024 * 1024 - 3));
      }, throwsFormatException);
    },
  );

  test('shared whitespace is trimmed once and blank rows remain omitted', () {
    final bytes = sharedWorkbook(' ' * 65536, 2000);
    final book = readXlsx(bytes);
    expect(
      identical(
        book.sheets.single.rows.first.single.lexical,
        book.sheets.single.rows.last.single.lexical,
      ),
      isTrue,
    );
    expect(workbookText(book), '【Shared】');
  });

  test('bounds work when whitespace references exceed the trim cache', () {
    final values = List.generate(257, (i) => ' ' * 4096 + '\t' * i);
    final book = XWorkbook([
      XSheet('S', [
        for (var repeat = 0; repeat < 100; repeat++)
          for (final value in values) [XCell('A1', CellKind.text, value)],
      ]),
    ], date1904: false);
    expect(() {
      workbookText(book);
    }, throwsFormatException);
  });
}
