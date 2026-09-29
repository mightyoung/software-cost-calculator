import 'dart:io';
import 'dart:typed_data';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// A font file with the given tables (tag → bytes), as a .ttf.
Uint8List _ttf(Map<String, List<int>> tables, {int base = 0}) {
  final count = tables.length;
  var at = base + 12 + count * 16;
  final out = BytesBuilder();
  final head = ByteData(12 + count * 16)
    ..setUint32(0, 0x00010000)
    ..setUint16(4, count);
  final bodies = <int>[];
  for (final (i, MapEntry(:key, :value)) in tables.entries.indexed) {
    head
      ..setUint32(
        12 + i * 16,
        ByteData.sublistView(Uint8List.fromList(key.codeUnits)).getUint32(0),
      )
      ..setUint32(20 + i * 16, at)
      ..setUint32(24 + i * 16, value.length);
    final padded = [...value, ...List.filled((4 - value.length % 4) % 4, 0)];
    bodies.addAll(padded);
    at += padded.length;
  }
  out
    ..add(head.buffer.asUint8List())
    ..add(bodies);
  return out.toBytes();
}

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_pdf'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the first face of a .ttc becomes a standalone .ttf', () {
    final tables = {
      'glyf': [1, 2, 3],
      'head': [4, 5, 6, 7, 8],
    };
    final ttf = _ttf(tables);
    expect(embeddableFont(ttf), same(ttf), reason: 'a .ttf is used as is');

    // Collection: 'ttcf', version, 1 face at offset 16, then the face with
    // table offsets counted from the start of the collection.
    final face = _ttf(tables, base: 16);
    final ttc =
        (BytesBuilder()
              ..add([
                0x74,
                0x74,
                0x63,
                0x66,
                0,
                1,
                0,
                0,
                0,
                0,
                0,
                1,
                0,
                0,
                0,
                16,
              ])
              ..add(face))
            .toBytes();
    expect(embeddableFont(ttc), ttf);

    final cff = _ttf({
      'CFF ': [1],
    });
    expect(embeddableFont(cff), isNull, reason: 'no TrueType outlines');
    expect(embeddableFont(Uint8List(3)), isNull);
  });

  test('money in PDFs is exact with separators', () {
    expect(pdfMoney('1234567.5'), '1,234,567.50');
    expect(pdfMoney('-3'), '-3.00');
    expect(pdfMoney('0.000001'), '0.000001');
  });

  final fontPath = [
    '/System/Library/Fonts/STHeiti Light.ttc',
    r'C:\Windows\Fonts\simhei.ttf',
    '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf',
  ].where((p) => File(p).existsSync()).firstOrNull;
  test(
    'quote sheet, cost budget and deviation table render as PDF with a system CJK font',
    () async {
      final s = device('A');
      final prod = s.save('product', product('离心泵', unit: '台'));
      final pro = s.save('project', project('P1'));
      s.save('project_item', {
        ...item(pro, 'material', productId: prod, qty: '2'),
        'unit': '台',
        'unit_cost': '32500',
      });
      final req = s.createSpecRequest('泵房', [
        draftItem('温湿度传感器', '★防护等级不低于IP65\n与采集器适配'),
      ], projectId: pro);
      final font = embeddableFont(File(fontPath!).readAsBytesSync())!;
      for (final pdf in [
        await s.quoteSheetPdf(pro, font),
        await s.costBudgetPdf(pro, font),
        await s.deviationPdf(req, font),
      ]) {
        expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
        expect(pdf.length, lessThan(200000), reason: 'font is subset');
      }
    },
    skip: fontPath == null ? 'no CJK system font on this machine' : false,
  );
}
