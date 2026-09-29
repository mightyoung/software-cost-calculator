import 'dart:typed_data';

import 'spec_compare.dart';
import 'spec_constraint.dart';
import 'spec_request.dart';
import 'store.dart';
import 'xlsx.dart';

/// Columns of the technical deviation table (design §10.4).
const deviationHeader = ['序号', '条款', '技术要求（原文）', '响应（具体值）', '偏离', '说明 / 依据'];

const _markSymbols = {
  ClauseMark.star: '★',
  ClauseMark.triangle: '▲',
  ClauseMark.none: '',
};

/// The deviation table of a requirement: per item a heading row (listed in
/// [headings]) naming the chosen material, then one row per clause. The
/// response is always the material's value, never "满足"; an unanswered
/// text clause says so.
({List<List<String>> rows, Set<int> headings}) deviationTable(
  Store s,
  String requestId,
) {
  final rows = <List<String>>[];
  final headings = <int>{};
  for (final item in s.specItemsOf(requestId)) {
    final d = item.data;
    final snap = (d['chosen_snapshot'] as Map?)?.cast<String, Object?>();
    final qty = d['qty'] == null ? '' : ' ×${d['qty']}${d['unit'] ?? ''}';
    final chosen = snap == null
        ? '未定选'
        : [
            snap['name'],
            snap['brand'],
            snap['model'],
          ].whereType<String>().join(' ');
    headings.add(rows.length);
    rows.add(['${d['seq']}', '', '${d['name']}$qty', '定选：$chosen', '', '']);
    final answers = {
      for (final r in snapshotRows(item) ?? const <Map<String, Object?>>[])
        r['n']: r,
    };
    for (final c in clausesOf(item)) {
      final r = answers[c.n];
      final outcome = r?['outcome'] == null
          ? Outcome.unknown
          : Outcome.values.byName(r!['outcome']! as String);
      rows.add([
        '${d['seq']}.${c.n}',
        _markSymbols[c.mark]!,
        c.text,
        r?['response'] as String? ??
            (snap == null
                ? ''
                : c.isText
                ? '（待人工填写）'
                : ''),
        deviationLabels[outcome]!,
        [
          if (r?['note'] case final String n) n,
          if (c.isText && r?['manual'] == true && r?['outcome'] != null) '人工判断',
        ].join('；'),
      ]);
    }
  }
  return (rows: rows, headings: headings);
}

extension SpecDeviation on Store {
  Uint8List deviationXlsx(String requestId) {
    final req = get('spec_request', requestId)!.data;
    final t = deviationTable(this, requestId);
    final top = [
      ['技术偏离表'],
      ['技术要求', '${req['title']}'],
      [],
      deviationHeader,
    ];
    return writeXlsx([
      SheetData(
        '技术偏离表',
        [...top, ...t.rows],
        widths: const [8, 6, 48, 36, 10, 30],
        boldRows: {
          0,
          top.length - 1,
          for (final h in t.headings) h + top.length,
        },
      ),
    ]);
  }
}
