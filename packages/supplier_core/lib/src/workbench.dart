import 'dart:convert';

import 'conflicts.dart';
import 'inquiries.dart';
import 'search.dart';
import 'store.dart';

/// An open inquiry and how far the suppliers have answered.
class OpenInquiry {
  OpenInquiry(
    this.id,
    this.data,
    this.project,
    this.replied,
    this.suppliers, {
    required this.daysLeft,
  });
  final String id;
  final Map<String, Object?> data;
  final String project;

  /// Suppliers that quoted at least one line, out of [suppliers].
  final int replied, suppliers;

  /// Days until the due date (negative: overdue); null without one.
  final int? daysLeft;
}

/// Budget lines of one running project still waiting for a quotation.
typedef PendingProject = ({String id, String name, int lines});

/// Everything that needs a person today, gathered from the whole ledger.
class Workbench {
  Workbench(this.inquiries, this.pending, this.attention, this.conflicts);

  /// Open inquiries, the most urgent first.
  final List<OpenInquiry> inquiries;
  final List<PendingProject> pending;
  final QuoteAttention attention;
  final int conflicts;

  bool get isEmpty =>
      inquiries.isEmpty &&
      pending.isEmpty &&
      attention.expiringCount == 0 &&
      conflicts == 0;
}

extension WorkbenchQueries on Store {
  Workbench workbench({DateTime? asOf}) {
    final now = asOf ?? clock();
    final today = DateTime.utc(now.year, now.month, now.day);
    String projectName(String id) =>
        get('project', id)?.data['name'] as String? ?? '项目';

    final inquiries = <OpenInquiry>[];
    for (final r in db.select(
      "SELECT id, data FROM inquiry WHERE deleted = 0 "
      "AND json_extract(data,'\$.status') = 'open'",
    )) {
      final id = r['id'] as String;
      final data = jsonDecode(r['data'] as String) as Map<String, Object?>;
      final project = get('project', data['project_id']! as String);
      if (project == null || project.deleted) continue;
      final answered = inquiryMatrix(id, asOf: now).answered;
      final due = data['due_date'] as String?;
      inquiries.add(
        OpenInquiry(
          id,
          data,
          project.data['name']! as String,
          answered.values.where((n) => n > 0).length,
          answered.length,
          daysLeft: due == null
              ? null
              : DateTime.parse('${due}T00:00:00Z').difference(today).inDays,
        ),
      );
    }
    // Due dates first (overdue on top), then the ones without a date.
    inquiries.sort(
      (a, b) => (a.daysLeft ?? 1 << 30).compareTo(b.daysLeft ?? 1 << 30),
    );

    final pending = [
      for (final r in db.select(
        "SELECT json_extract(i.data,'\$.project_id') AS project, count(*) AS n "
        'FROM project_item i JOIN project p '
        "ON p.id = json_extract(i.data,'\$.project_id') AND p.deleted = 0 "
        "AND json_extract(p.data,'\$.status') IN ('planning', 'active') "
        "WHERE i.deleted = 0 AND json_extract(i.data,'\$.category') = 'material' "
        "AND json_extract(i.data,'\$.quotation_id') IS NULL "
        'GROUP BY project ORDER BY n DESC',
      ))
        (
          id: r['project'] as String,
          name: projectName(r['project'] as String),
          lines: r['n'] as int,
        ),
    ];

    return Workbench(
      inquiries,
      pending,
      quoteAttention(asOf: now, limit: 8),
      openConflicts().length,
    );
  }
}

/// A message to send a supplier by WeChat or email: the lines to quote with
/// requirements and quantities, the due date and what the price must state.
String inquiryMessage(
  Store store,
  String inquiryId, {
  String? supplierName,
  String? sender,
}) {
  final inquiry = store.get('inquiry', inquiryId)!.data;
  final project = store.get('project', inquiry['project_id']! as String)!.data;
  final lines = <String>[];
  for (final itemId in (inquiry['item_ids']! as List).cast<String>()) {
    final item = store.get('project_item', itemId);
    if (item == null || item.deleted) continue;
    final d = item.data;
    final product = d['product_id'] == null
        ? null
        : store.get('product', d['product_id']! as String)?.data;
    final name = [
      product?['name'] ?? d['name'],
      product?['brand'],
      product?['model'],
    ].whereType<String>().join(' ');
    String line(String label, Object? text) => text == null
        ? ''
        : '\n   $label：${(text as String).replaceAll('\n', '；')}';
    lines.add(
      '${lines.length + 1}. $name，${d['qty']} ${d['unit']}'
      '${line('规格', product?['specification'])}'
      '${line('要求', d['requirement'])}',
    );
  }
  final due = inquiry['due_date'] as String?;
  final tax = project['tax_mode'] == 'included' ? '含税' : '不含税';
  return [
    '${supplierName == null ? '您好' : '$supplierName 您好'}，'
        '我们的「${project['name']}」项目需要以下产品报价：',
    ...lines,
    '请报$tax单价（${project['currency']}），并注明税率、交期、报价有效期和价格包含的内容（运费、安装等）'
        '${due == null ? '。' : '，请在 $due 前回复。'}',
    if (inquiry['notes'] case final String n when n.isNotEmpty) '备注：$n',
    if (sender != null && sender.isNotEmpty) '谢谢！$sender',
  ].join('\n');
}
