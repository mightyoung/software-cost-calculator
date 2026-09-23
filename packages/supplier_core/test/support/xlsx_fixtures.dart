import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:supplier_core/supplier_core.dart';

const mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const relNs =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const pkgNs = 'http://schemas.openxmlformats.org/package/2006/relationships';

class XlsxSource implements InputSource {
  XlsxSource(this.bytes);
  final List<int> bytes;
  @override
  String get displayName => 'fixture.xlsx';
  @override
  Future<int> length() async => bytes.length;
  @override
  Stream<List<int>> openRange(int start, int endExclusive) async* {
    for (var at = start; at < endExclusive; at += 65536) {
      yield bytes.sublist(at, (at + 65536).clamp(at, endExclusive));
    }
  }
}

XlsxSource xlsxFixture({
  String? sheet,
  String? shared,
  String? workbook,
  String? relations,
  Map<String, String> overrides = const {},
}) {
  final parts = <String, String>{
    '[Content_Types].xml':
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>',
    '_rels/.rels':
        '<Relationships xmlns="$pkgNs"><Relationship Id="root" Type="$relNs/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    'xl/_rels/workbook.xml.rels':
        relations ??
        '<Relationships xmlns="$pkgNs"><Relationship Id="s" Type="$relNs/worksheet" Target="worksheets/sheet1.xml"/>${shared == null ? '' : '<Relationship Id="str" Type="$relNs/sharedStrings" Target="sharedStrings.xml"/>'}</Relationships>',
    'xl/workbook.xml':
        workbook ??
        '<workbook xmlns="$mainNs" xmlns:r="$relNs"><workbookPr date1904="true"/><sheets><sheet name="业务" sheetId="1" r:id="s"/></sheets></workbook>',
    'xl/worksheets/sheet1.xml':
        sheet ??
        '<worksheet xmlns="$mainNs"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>编号</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>00123</t></is></c><c r="B2" s="2"><v>1.2300E+2</v></c></row></sheetData></worksheet>',
    if (shared != null) 'xl/sharedStrings.xml': shared,
    ...overrides,
  };
  final archive = Archive();
  for (final entry in parts.entries) {
    final bytes = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return XlsxSource(ZipEncoder().encode(archive)!);
}

String worksheet(String content) =>
    '<worksheet xmlns="$mainNs"><sheetData>$content</sheetData></worksheet>';
