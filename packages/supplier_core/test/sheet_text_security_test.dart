import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

Uint8List continuationWorkbook(String text, int count) {
  final parts = {
    'xl/workbook.xml':
        '<workbook xmlns:r="r"><sheets><sheet name="S" r:id="s"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels':
        '<Relationships><Relationship Id="s" Target="worksheets/s.xml"/></Relationships>',
    'xl/sharedStrings.xml': '<sst><si><t>$text</t></si></sst>',
    'xl/worksheets/s.xml':
        '<worksheet><sheetData>'
        '<row><c r="A1" t="inlineStr"><is><t>名称</t></is></c>'
        '<c r="B1" t="inlineStr"><is><t>技术参数</t></is></c>'
        '<c r="C1" t="inlineStr"><is><t>品牌</t></is></c></row>'
        '<row><c r="A2" t="inlineStr"><is><t>泵</t></is></c></row>'
        '${[for (var i = 0; i < count; i++) '<row><c r="B${i + 3}" t="s"><v>0</v></c></row>'].join()}'
        '</sheetData></worksheet>',
  };
  final archive = Archive();
  for (final part in parts.entries) {
    final bytes = utf8.encode(part.value);
    archive.addFile(ArchiveFile(part.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  for (final materials in [false, true]) {
    test(
      'offer continuation rejects amplified shared strings ($materials)',
      () {
        final bytes = continuationWorkbook('x' * 32767, 3);
        expect(bytes.length, lessThan(10000));
        expect(
          () => offersFromWorkbook(readXlsx(bytes), materials: materials),
          throwsFormatException,
        );
      },
    );
  }

  test(
    'requirements reject amplified shared strings before clause parsing',
    () {
      final bytes = continuationWorkbook('x' * 32767, 3);
      expect(() => requirementRows(readXlsx(bytes)), throwsFormatException);
      expect(
        () => specItemsFromWorkbook(readXlsx(bytes)),
        throwsFormatException,
      );
    },
  );

  test('total text budget also covers independent rows and blank strings', () {
    for (final value in ['x' * 32767, ' ' * 32767]) {
      final book = XWorkbook([
        XSheet('S', [
          [
            const XCell('A1', CellKind.text, '名称'),
            const XCell('B1', CellKind.text, '技术参数'),
          ],
          for (var i = 0; i < 33; i++)
            [
              XCell('A2', CellKind.text, '泵$i'),
              XCell('B2', CellKind.text, value),
            ],
        ]),
      ], date1904: false);
      expect(
        () => offersFromWorkbook(book, materials: true),
        throwsFormatException,
      );
      expect(() => requirementRows(book), throwsFormatException);
    }
  });

  test('pasted continuation table rejects oversized accumulated evidence', () {
    final book = tableFromText(
      '名称\t技术参数\n泵\t${'x' * 32767}\n\t${'x' * 32767}\n\tmore',
    )!;
    expect(
      () => offersFromWorkbook(book, materials: true),
      throwsFormatException,
    );
    expect(
      () => specItemsFromText(
        '名称\t技术参数\n泵\t${'x' * 32767}\n\t${'x' * 32767}\n\tmore',
      ),
      throwsFormatException,
    );
  });

  test('normal merged rows retain newlines, fields and requirement text', () {
    final book = tableFromText(
      '名称\t技术参数\t品牌\t备注\n泵\t流量10\t甲\t首行\n\t扬程20\t\t续行',
    )!;
    final offer = offersFromWorkbook(book)!.single;
    expect(offer['specification'], '流量10\n扬程20');
    expect(offer['notes'], '首行\n续行');
    expect(offer['supplier'], '甲');
    expect(requirementRows(book)!.single['specification'], '流量10\n扬程20');
  });

  test('field budget counts separators and preserves its exact boundary', () {
    final book = tableFromText(
      '名称\t技术参数\n泵\t${'x' * 32767}\n\t${'x' * 32768}',
    )!;
    expect(requirementRows(book)!.single['specification']!.length, 65536);
    expect(offersFromWorkbook(book, materials: true), hasLength(1));
    book.sheets.single.rows.add([
      const XCell('A4', CellKind.blank, ''),
      const XCell('B4', CellKind.text, 'x'),
    ]);
    expect(() => requirementRows(book), throwsFormatException);
    expect(
      () => offersFromWorkbook(book, materials: true),
      throwsFormatException,
    );
  });

  test('notes use the same continuation limit as specifications', () {
    final book = tableFromText(
      '名称\t品牌\t备注\n泵\t甲\t${'x' * 32767}\n\t\t${'x' * 32767}\n\t\tmore',
    )!;
    expect(() => offersFromWorkbook(book), throwsFormatException);
  });

  test('many small continuations are assembled once without losing text', () {
    final book = readXlsx(continuationWorkbook('x', 20000));
    final text = requirementRows(book)!.single['specification']!;
    expect(text.length, 39999);
    expect(text.split('\n'), hasLength(20000));
  });

  test('unmatched header brackets do not require backtracking', () {
    final book = tableFromText('名称\t${'(' * 60000}\n泵\tx')!;
    expect(offersFromWorkbook(book, materials: true), isNull);
    expect(requirementRows(book), isNull);
  });

  test('mixed bracket header suffixes retain existing recognition', () {
    final book = tableFromText('名称（设备)\t技术参数(说明）\n泵\t流量10')!;
    expect(offersFromWorkbook(book, materials: true)!.single['name'], '泵');
    expect(requirementRows(book)!.single['specification'], '流量10');
  });

  test('oversized pasted tables are rejected before allocating cells', () {
    expect(
      () => tableFromText('名称\t${'x' * (1024 * 1024)}'),
      throwsFormatException,
    );
    expect(tableFromText('x' * (1024 * 1024 + 1)), isNull);
  });
}
