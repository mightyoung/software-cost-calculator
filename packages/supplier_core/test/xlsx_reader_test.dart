import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:supplier_core/src/exchange/xlsx_reader.dart';
import 'package:supplier_core/src/exchange/xlsx_staging.dart';
import 'package:test/test.dart';
import 'support/xlsx_fixtures.dart';

void main() {
  late XlsxStaging staging;
  setUp(() => staging = XlsxStaging(NativeDatabase.memory()));
  tearDown(() => staging.close());
  const reader = BoundedXlsxReader();
  test(
    'lexical text/numeric types, date1904, style and actual counts',
    () async {
      final source = xlsxFixture();
      final profile = await reader.readVolume(source, staging);
      expect(profile.date1904, isTrue);
      expect(profile.rows, 2);
      expect(profile.cells, 3);
      expect(profile.sourceDigest, sha256.convert(source.bytes).toString());
      final cells = await staging.cellsPage(2);
      expect(cells[0].cell.lexical, '00123');
      expect(cells[0].rawType, 'inlineStr');
      expect(cells[1].cell.lexical, '1.2300E+2');
      expect(cells[1].styleIndex, 2);
      expect((await staging.rowsPage(limit: 1)).single.row, 1);
      expect((await staging.rowsPage(afterRow: 1)).single.row, 2);
      expect((await staging.cellsPage(2, afterColumn: 1)).single.column, 2);
    },
  );
  test('shared strings SQL persists more than cache; rich text exact', () async {
    final strings =
        '<sst xmlns="$mainNs">${List.generate(40, (i) => '<si><r><t>00</t></r><r><t>$i</t></r></si>').join()}</sst>';
    final sheet = worksheet(
      List.generate(
        40,
        (i) => '<row r="${i + 1}"><c r="A${i + 1}" t="s"><v>$i</v></c></row>',
      ).join(),
    );
    final p = await reader.readVolume(
      xlsxFixture(sheet: sheet, shared: strings),
      staging,
    );
    expect(p.sharedStrings, 40);
    expect((await staging.cellsPage(40)).single.cell.lexical, '0039');
    expect(await staging.stringAt(0), '000');
  });
  test(
    'formula nodes including empty shared formula remain row errors',
    () async {
      await reader.readVolume(
        xlsxFixture(
          sheet: worksheet(
            '<row r="1"><c r="A1" t="str"><f t="shared" si="0"/><v>cached</v></c><c r="B1" t="b"><v>1</v></c><c r="C1" t="e"><v>#N/A</v></c></row>',
          ),
        ),
        staging,
      );
      final cells = await staging.cellsPage(1);
      expect(cells[0].cell.formula, '');
      expect(cells[0].cell.lexical, 'cached');
      for (final c in cells) {
        expect(() => c.cell.sourcePresence, throwsA(anything));
      }
    },
  );
  for (final entry in <String, String>{
    'duplicate coordinate': '<row r="1"><c r="A1"/><c r="A1"/></row>',
    'wrong row': '<row r="1"><c r="A2"/></row>',
    'unsorted coordinate': '<row r="1"><c r="B1"/><c r="A1"/></row>',
    'duplicate row': '<row r="1"/><row r="1"/>',
    'missing row coordinate': '<row><c r="A1"/></row>',
    'unknown shared string': '<row r="1"><c r="A1" t="s"><v>0</v></c></row>',
    'duplicate value': '<row r="1"><c r="A1"><v>1</v><v>2</v></c></row>',
    'unquoted attribute': '<row r=1/>',
    'missing assignment': '<row r/>',
    'oversized cell':
        '<row r="1"><c r="A1" t="inlineStr"><is><t>${'😀' * 16384}</t></is></c></row>',
  }.entries) {
    test('reject ${entry.key} and quarantine', () async {
      await expectLater(
        reader.readVolume(xlsxFixture(sheet: worksheet(entry.value)), staging),
        throwsA(anything),
      );
      await expectLater(staging.rowsPage(), throwsStateError);
    });
  }
  for (final entry in <String, String>{
    'merged':
        '<worksheet xmlns="$mainNs"><sheetData/><mergeCells><mergeCell ref="A1:B1"/></mergeCells></worksheet>',
    'wrong namespace': '<worksheet xmlns="urn:evil"><sheetData/></worksheet>',
    'undeclared prefix':
        '<worksheet xmlns="$mainNs"><x:sheetData/></worksheet>',
    'DTD':
        '<!DOCTYPE worksheet [<!ENTITY a "x">]><worksheet xmlns="$mainNs"><sheetData/></worksheet>',
    'bad nesting': '<worksheet xmlns="$mainNs"><sheetData></worksheet>',
    'multiple roots':
        '<worksheet xmlns="$mainNs"><sheetData/></worksheet><worksheet xmlns="$mainNs"/>',
  }.entries) {
    test('reject ${entry.key}', () async {
      await expectLater(
        reader.readVolume(xlsxFixture(sheet: entry.value), staging),
        throwsA(anything),
      );
    });
  }
  test(
    '5000 data plus header enforced by actual row elements, not dimension',
    () async {
      final sheet = worksheet(
        List.generate(5002, (i) => '<row r="${i + 1}"/>').join(),
      );
      await expectLater(
        reader.readVolume(xlsxFixture(sheet: sheet), staging),
        throwsA(anything),
      );
    },
  );
  test('selected sheet relationship is respected', () async {
    final workbook =
        '<workbook xmlns="$mainNs" xmlns:r="$relNs"><sheets><sheet name="first" r:id="a"/><sheet name="second" r:id="b"/></sheets></workbook>';
    final relations =
        '<Relationships xmlns="$pkgNs"><Relationship Id="a" Type="$relNs/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="b" Type="$relNs/worksheet" Target="worksheets/sheet2.xml"/></Relationships>';
    final p = await reader.readVolume(
      xlsxFixture(
        workbook: workbook,
        relations: relations,
        overrides: {'xl/worksheets/sheet2.xml': worksheet('<row r="7"/>')},
      ),
      staging,
      sheetName: 'second',
    );
    expect(p.sheetName, 'second');
    expect((await staging.rowsPage()).single.row, 7);
  });

  test(
    'ST_Xstring single-pass decode retains CR and escaped-looking IDs',
    () async {
      await reader.readVolume(
        xlsxFixture(
          sheet: worksheet(
            '<row r="1"><c r="A1" t="inlineStr"><is><t>A_x000D_B_x005F_x0041_</t></is></c><c r="B1" t="s"><v>0</v></c></row>',
          ),
          shared: '<sst xmlns="$mainNs"><si><t>_xD83D__xDE00_</t></si></sst>',
        ),
        staging,
      );
      final cells = await staging.cellsPage(1);
      expect(cells[0].cell.lexical, 'A\rB_x0041_');
      expect(cells[1].cell.lexical, '😀');
    },
  );
  test(
    'CDATA and escaped ampersands remain literal while date type is preserved',
    () async {
      await reader.readVolume(
        xlsxFixture(
          sheet: worksheet(
            '<row r="1"><c r="A1" t="inlineStr"><is><t><![CDATA[A&bogus;]]>&amp;B</t></is></c><c r="B1" t="d"><v>2026-09-18</v></c></row>',
          ),
        ),
        staging,
      );
      final cells = await staging.cellsPage(1);
      expect(cells.first.cell.lexical, 'A&bogus;&B');
      expect(cells.last.rawType, 'd');
      expect(() => cells.last.cell.sourcePresence, throwsA(anything));
    },
  );
  for (final bad in [
    '<v>1<garbage>9</garbage>2</v>',
    '<v>A&bogus;B</v>',
    '<v>A&B</v>',
    '<v>A]]>B</v>',
    '<is><garbage>00123</garbage></is>',
    '<is>00123</is>',
    '<is><r><garbage>00123</garbage></r></is>',
    '<v>&#0;</v>',
    '<is><t>_x0001_</t></is>',
    '<is><t>_xD800_</t></is>',
  ]) {
    test('strict scalar/entity/escaped character $bad', () async {
      await expectLater(
        reader.readVolume(
          xlsxFixture(
            sheet: worksheet(
              '<row r="1"><c r="A1" t="${bad.startsWith('<is>') ? 'inlineStr' : 'n'}">$bad</c></row>',
            ),
          ),
          staging,
        ),
        throwsA(anything),
      );
    });
  }
  test(
    'mid-parse cancellation preserves error and quarantines staging',
    () async {
      final cancelled = StateError('cancelled');
      var checks = 0;
      await expectLater(
        reader.readVolume(
          xlsxFixture(
            sheet: worksheet(
              List.generate(130, (i) => '<row r="${i + 1}"/>').join(),
            ),
          ),
          staging,
          checkpoint: () async {
            if (++checks == 7) throw cancelled;
          },
        ),
        throwsA(same(cancelled)),
      );
      expect(checks, 7);
      await expectLater(staging.profile(), throwsStateError);
    },
  );
  test('explicit row policy is independent of sync-volume default', () async {
    final profile = await const BoundedXlsxReader(maxDataRows: 6000).readVolume(
      xlsxFixture(
        sheet: worksheet(
          List.generate(5002, (i) => '<row r="${i + 1}"/>').join(),
        ),
      ),
      staging,
    );
    expect(profile.rows, 5002);
  });

  test(
    'last nonselected resource CRC failure cannot publish earlier rows',
    () async {
      final source = xlsxFixture(overrides: {'unknown.bin': 'unread resource'});
      final bytes = Uint8List.fromList(source.bytes),
          data = ByteData.sublistView(Uint8List.fromList(source.bytes));
      // Change both advertised CRC values, leaving the payload unchanged.
      var at = data.getUint32(data.lengthInBytes - 6, Endian.little);
      while (data.getUint32(at, Endian.little) == 0x02014b50) {
        final length = data.getUint16(at + 28, Endian.little);
        final name = utf8.decode(bytes.sublist(at + 46, at + 46 + length));
        if (name == 'unknown.bin') {
          final local = data.getUint32(at + 42, Endian.little);
          final crc = data.getUint32(at + 16, Endian.little) ^ 1;
          data.setUint32(at + 16, crc, Endian.little);
          data.setUint32(local + 14, crc, Endian.little);
          break;
        }
        at +=
            46 +
            length +
            data.getUint16(at + 30, Endian.little) +
            data.getUint16(at + 32, Endian.little);
      }
      await expectLater(
        reader.readVolume(XlsxSource(data.buffer.asUint8List()), staging),
        throwsA(anything),
      );
      await expectLater(staging.rowsPage(), throwsStateError);
    },
  );
  for (final body in [
    '<worksheet xmlns="$mainNs" xmlns:q="urn:x"><sheetData a:1b="x"/></worksheet>',
    '<worksheet xmlns="$mainNs" xmlns:q="http://www.w3.org/XML/1998/namespace"><sheetData/></worksheet>',
    '<worksheet xmlns="$mainNs"><!--bad--comment--><sheetData/></worksheet>',
    '<?xml version=1.0?><worksheet xmlns="$mainNs"><sheetData/></worksheet>',
    '<worksheet xmlns="$mainNs"><sheetData x="A&bad;"/></worksheet>',
  ]) {
    test('strict namespace/declaration/attribute rejection $body', () async {
      await expectLater(
        reader.readVolume(xlsxFixture(sheet: body), staging),
        throwsA(anything),
      );
    });
  }

  const calcNs =
      'http://schemas.microsoft.com/office/spreadsheetml/2018/calcfeatures';
  const extUri = '{B58B0392-4F1F-4190-BB64-5DF3571DCE5F}';
  String workbookWith(String extension, {String mc = ''}) =>
      '<workbook xmlns="$mainNs" xmlns:r="$relNs" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" $mc><sheets><sheet name="业务" r:id="s"/></sheets>$extension</workbook>';
  String ext(String body, {String uri = extUri}) =>
      '<extLst><ext uri="$uri" xmlns:xcalcf="$calcNs">$body</ext></extLst>';
  test(
    'specific WPS workbook calculation metadata is structurally ignored',
    () async {
      final profile = await reader.readVolume(
        xlsxFixture(
          workbook: workbookWith(
            ext(
              '<xcalcf:calcFeatures><xcalcf:feature name="microsoft.com:LET_WF"/></xcalcf:calcFeatures>',
            ),
          ),
        ),
        staging,
      );
      expect(profile.rows, 2);
      expect((await staging.cellsPage(2)).first.cell.lexical, '00123');
    },
  );
  for (final extension in [
    ext('<xcalcf:calcFeatures/>', uri: 'wrong'),
    ext(
      '<xcalcf:calcFeatures><sheet name="ignored-business" r:id="s"/></xcalcf:calcFeatures>',
    ),
    ext('<xcalcf:calcFeatures>business text</xcalcf:calcFeatures>'),
    ext('<xcalcf:calcFeatures><xcalcf:unknown/></xcalcf:calcFeatures>'),
    '<bookViews>${ext('<xcalcf:calcFeatures/>')}</bookViews>',
  ]) {
    test(
      'calculation extension cannot bypass location/URI/QName/text bounds $extension',
      () async {
        await expectLater(
          reader.readVolume(
            xlsxFixture(workbook: workbookWith(extension)),
            staging,
          ),
          throwsA(anything),
        );
      },
    );
  }
  for (final instruction in [
    'MustUnderstand="r"',
    'ProcessContent="r:sheet"',
    'PreserveElements="r:sheet"',
    'Unknown="x"',
    'Ignorable="unbound"',
  ]) {
    test('unsupported or unbound MC instruction $instruction', () async {
      await expectLater(
        reader.readVolume(
          xlsxFixture(workbook: workbookWith('', mc: 'mc:$instruction')),
          staging,
        ),
        throwsA(anything),
      );
    });
  }
  test(
    'Ignorable is not permission to discard unknown business elements',
    () async {
      final sheet =
          '<worksheet xmlns="$mainNs" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:x="urn:unknown" mc:Ignorable="x"><sheetData><x:row><x:c>00123</x:c></x:row></sheetData></worksheet>';
      await expectLater(
        reader.readVolume(xlsxFixture(sheet: sheet), staging),
        throwsA(anything),
      );
    },
  );

  String styles(String body) =>
      '<styleSheet xmlns="$mainNs"><extLst><ext uri="{EB79DEF2-80B8-43e5-95BD-54CBDDF9020C}" xmlns:x14="http://schemas.microsoft.com/office/spreadsheetml/2009/9/main">$body</ext></extLst></styleSheet>';
  test('empty WPS slicer style metadata does not affect raw cells', () async {
    await reader.readVolume(
      xlsxFixture(
        overrides: {
          'xl/styles.xml': styles(
            '<x14:slicerStyles defaultSlicerStyle="SlicerStyleLight1"/>',
          ),
        },
      ),
      staging,
    );
    expect((await staging.cellsPage(2)).first.cell.lexical, '00123');
  });
  for (final body in [
    '<x14:slicerStyles defaultSlicerStyle="x"><x14:slicerStyle name="x"/></x14:slicerStyles>',
    '<x14:slicerStyles defaultSlicerStyle="x">business text</x14:slicerStyles>',
    '<x14:slicerStyles defaultSlicerStyle="x" unknown="y"/>',
  ]) {
    test('nonempty/unknown slicer metadata is unsupported $body', () async {
      await expectLater(
        reader.readVolume(
          xlsxFixture(overrides: {'xl/styles.xml': styles(body)}),
          staging,
        ),
        throwsA(anything),
      );
    });
  }
}
