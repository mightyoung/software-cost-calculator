import 'dart:convert';
import 'dart:io';
import 'package:excel/excel.dart';

// Encoder-only evidence. Does not implement the formal revision protocol.
void main() {
  final golden = jsonDecode(File('.omx/specs/supplier-sync-v1-golden.json').readAsStringSync());
  final sheets = <String, List<List<String>>>{
    '说明': [['format', 'supplier-inquiry-sync-v1']],
    for (final pair in golden['business_digest_input'])
      pair[0] as String: [for (final row in pair[1]) List<String>.from(row)],
    '_manifest': [
      ['format', 'supplier-inquiry-sync'], ['protocol_version', '1'], ['schema_version', '1'],
      ['export_id', '99999999-9999-4999-8999-999999999999'],
      ['exported_at', '2026-09-16T00:00:00.000Z'], ['exporter_version', 'v' * 64],
      ['revision_count', '3'], ['entity_count', '3'],
      ['revisions_digest', golden['expected_revisions_digest']],
      ['business_digest', golden['expected_business_digest']],
    ],
    '_revisions': [
      ['revision_id', 'entity_type', 'entity_id', 'envelope_json'],
      for (final row in golden['revisions_digest_input'])
        [row[0], jsonDecode(row[1])['entity_type'], jsonDecode(row[1])['entity_id'], row[1]],
    ],
  };
  Map<String, Object> measure(String name, Map<String, List<List<String>>> input) {
    final book = Excel.createExcel();
    book.rename('Sheet1', input.keys.first);
    var budget = 1048576;
    var cells = 0;
    for (final entry in input.entries) {
      for (final row in entry.value) {
        book[entry.key].appendRow(row.map(TextCellValue.new).toList());
        for (final cell in row) {
          final escaped = cell.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
          budget += 256 + 2 * utf8.encode(escaped).length;
          cells++;
        }
      }
    }
    final bytes = book.encode()!;
    if (bytes.length > budget || bytes.length > 20 * 1024 * 1024) throw StateError('Encoder exceeds budget');
    if (name == 'v1-golden-fixed-matrices') File('artifacts/supplier-probe/v1-golden-encoder.xlsx').writeAsBytesSync(bytes);
    return {'fixture': name, 'cells': cells, 'xlsxBytes': bytes.length, 'budgetB': budget, 'pass': true};
  }
  print(const JsonEncoder.withIndent('  ').convert([
    measure('v1-golden-fixed-matrices', sheets),
    measure('100-unique-24000-unit-escaped-strings', {'encoder_stress': [
      for (var i = 0; i < 100; i++) ['${i.toString().padLeft(4, '0')}${'<&>' * 7998}ab'],
    ]}),
    measure('100-unique-32767-unit-unicode-cells', {'encoder_stress': [
      for (var i = 0; i < 100; i++) ['${i.toString().padLeft(4, '0')}${'😀' * 16381}x'],
    ]}),
  ]));
}
