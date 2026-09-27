import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';
import '../quotes/quote_extras.dart';
import 'award_dialog.dart';
import 'cell_dialog.dart';

const _lineWidth = 230.0, _cellWidth = 180.0, _awardWidth = 200.0;

Future<void> openInquiry(BuildContext context, AppState state, String id) =>
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InquiryPage(state: state, id: id),
      ),
    );

/// Lines × invited suppliers. Each cell is that supplier's quotation for the
/// line; each row is awarded to one of them, which prices the budget line.
class InquiryPage extends StatelessWidget {
  const InquiryPage({super.key, required this.state, required this.id});
  final AppState state;
  final String id;

  Store get store => state.store;

  String _supplierName(String sid) =>
      store.get('supplier', sid)?.data['name'] as String? ?? '未知供应商';

  Future<void> _export(BuildContext context, String title, String sid) async {
    final saved = await saveBytes(
      '询价表-$title-${_supplierName(sid)}.xlsx',
      store.exportInquirySheet(id, sid),
      extensions: ['xlsx'],
    );
    if (saved && context.mounted) {
      toast(context, '已导出，发给${_supplierName(sid)}填写');
    }
  }

  Future<void> _import(BuildContext context, String sid) async {
    final file = await pickBytes(['xlsx']);
    if (file == null || !context.mounted) return;
    final List<InquiryRowPlan> plans;
    try {
      plans = store.planInquirySheet(file.bytes, id, sid);
    } on FormatException catch (e) {
      return toast(context, '无法读取 ${file.name}：${e.message}');
    }
    final good = plans.where((p) => p.error == null).length;
    final errors = [
      for (final p in plans)
        if (p.error != null) p,
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('导入 ${_supplierName(sid)} 的报价'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$good 行报价可以导入，已报过的行会更新为新价格。原表会作为附件保存。'),
            for (final e in errors.take(5))
              Text(
                '第 ${e.row} 行：${e.error}',
                style: const TextStyle(color: Tokens.red),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: good == 0 ? null : () => Navigator.pop(context, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    late int n;
    final err = state.write(
      (s) => s.transaction(() {
        final att = s.addAttachment(file.name, file.bytes);
        n = s.applyInquirySheet(
          id,
          sid,
          plans,
          inquirer: state.setting('inquirer') ?? state.deviceName,
          attachmentIds: [att],
        );
      }),
    );
    toast(context, err ?? '已导入 $n 行报价');
  }

  Future<void> _award(BuildContext context, InquiryRow row) async {
    final cells = row.cells.whereType<InquiryCell>().toList();
    final best = cells.where((c) => c.lowest).firstOrNull ?? cells.first;
    final awarded = await showAwardDialog(
      context,
      state,
      itemId: row.itemId,
      initial: best.quotationId,
      choices: [
        for (final c in cells)
          (
            quotationId: c.quotationId,
            label:
                '${quoteLabel(store, c.data, effective: c.effectivePrice)}'
                '${c.lowest ? ' · 最低' : ''}${c.valid ? '' : ' · 无效'}',
          ),
      ],
    );
    if (awarded && context.mounted) toast(context, '已定标，预算已更新');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final record = store.get('inquiry', id);
      if (record == null || record.deleted) {
        return const Scaffold(
          body: EmptyState(title: '询价单已删除', body: ''),
        );
      }
      final m = store.inquiryMatrix(id);
      final title = m.inquiry['title']! as String;
      final open = m.inquiry['status'] == 'open';
      final awardedRows = m.rows
          .where((r) => r.cells.any((c) => c?.awarded ?? false))
          .length;
      return Scaffold(
        appBar: AppBar(
          backgroundColor: Tokens.canvas,
          title: Text(title),
          actions: [
            TextButton(
              onPressed: () => state.write(
                (s) => s.save('inquiry', {
                  ...record.data,
                  'status': open ? 'closed' : 'open',
                }, id: id),
              ),
              child: Text(open ? '标记为已结束' : '重新打开'),
            ),
            const SizedBox(width: 12),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                [
                  '${m.rows.length} 行 × ${m.suppliers.length} 家供应商',
                  '截止 ${m.inquiry['due_date'] ?? '不限'}',
                  '已定标 $awardedRows/${m.rows.length}',
                  if (!open) '已结束',
                ].join(' · '),
                style: const TextStyle(color: Tokens.ink2),
              ),
              const SizedBox(height: 4),
              const Text(
                '点单元格录入或修改报价；有效单价 = 单价 + 附加费用 ÷ 数量。每行比较的是口径（币种、含税、单位）与项目一致且仍有效的报价。',
                style: TextStyle(fontSize: 12, color: Tokens.ink3),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width:
                        _lineWidth +
                        _cellWidth * m.suppliers.length +
                        _awardWidth,
                    child: Column(
                      children: [
                        _header(context, m, title),
                        Expanded(
                          child: ListView(
                            children: [
                              for (final r in m.rows) _row(context, m, r),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _header(
    BuildContext context,
    InquiryMatrix m,
    String title,
  ) => Container(
    color: Tokens.sunken,
    child: Row(
      children: [
        const SizedBox(
          width: _lineWidth,
          child: Padding(
            padding: EdgeInsets.all(10),
            child: Text(
              '物料 / 数量',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
        for (final sid in m.suppliers)
          SizedBox(
            width: _cellWidth,
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 0, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _supplierName(sid),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '已报 ${m.answered[sid]}/${m.rows.length}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Tokens.ink3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '询价表',
                  icon: const Icon(Icons.more_vert, size: 18),
                  onSelected: (v) => v == 'export'
                      ? _export(context, title, sid)
                      : _import(context, sid),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'export', child: Text('导出询价表（发给供应商）')),
                    PopupMenuItem(value: 'import', child: Text('导入供应商回填的表')),
                  ],
                ),
              ],
            ),
          ),
        const SizedBox(
          width: _awardWidth,
          child: Padding(
            padding: EdgeInsets.all(10),
            child: Text('定标', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    ),
  );

  Widget _row(BuildContext context, InquiryMatrix m, InquiryRow r) {
    final p = r.item['product_id'] == null
        ? null
        : store.get('product', r.item['product_id']! as String)?.data;
    final won = r.cells
        .whereType<InquiryCell>()
        .where((c) => c.awarded)
        .firstOrNull;
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Tokens.rule)),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: _lineWidth,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        p?['name'] ?? r.item['name'],
                        p?['model'],
                      ].whereType<String>().join(' '),
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    Text(
                      '${qty(r.item['qty']! as String)} ${r.item['unit']}',
                      style: const TextStyle(fontSize: 12, color: Tokens.ink3),
                    ),
                  ],
                ),
              ),
            ),
            for (var i = 0; i < m.suppliers.length; i++)
              SizedBox(
                width: _cellWidth,
                child: _Cell(
                  cell: r.cells[i],
                  onTap: () => showInquiryCell(
                    context,
                    state,
                    inquiryId: id,
                    itemId: r.itemId,
                    supplierId: m.suppliers[i],
                    current: r.cells[i]?.data,
                  ),
                ),
              ),
            SizedBox(
              width: _awardWidth,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: won != null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_supplierName(won.data['supplier_id']! as String)} '
                            '${money(won.data['deal_price'] as String?, prefix: '¥')}',
                            style: const TextStyle(color: Tokens.accentDeep),
                          ),
                          if (won.data['award_note'] != null)
                            Text(
                              won.data['award_note']! as String,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Tokens.ink3,
                              ),
                            ),
                          TextButton(
                            onPressed: () => state.write(
                              (s) => s.withdrawAward(won.quotationId),
                            ),
                            child: const Text('撤销定标'),
                          ),
                        ],
                      )
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton(
                          onPressed: r.cells.any((c) => c != null)
                              ? () => _award(context, r)
                              : null,
                          child: const Text('定标'),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.cell, required this.onTap});
  final InquiryCell? cell;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = cell;
    if (c == null) {
      return InkWell(
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: Text('录入报价', style: TextStyle(color: Tokens.ink3)),
        ),
      );
    }
    final d = c.data;
    final scope = scopeText(d['includes']);
    final tags = <Widget>[
      if (c.awarded)
        const HintTag('已定标', icon: Icons.verified_outlined, tone: HintTone.info)
      else if (c.lowest)
        const HintTag('最低', icon: Icons.south, tone: HintTone.info),
      if (!c.comparable)
        const HintTag('口径不同', icon: Icons.block)
      else if (!c.valid)
        const HintTag('已失效或未达起订量', icon: Icons.block),
      if (c.deviation != null && c.deviation!.abs() >= historyWarnPercent)
        HintTag(
          '比均价 ${c.deviation! > 0 ? '+' : ''}${c.deviation}%',
          icon: Icons.history,
        ),
    ];
    return InkWell(
      onTap: onTap,
      child: Container(
        color: c.awarded || c.lowest ? Tokens.accentTint : null,
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              money(c.effectivePrice, prefix: '¥'),
              style: TextStyle(
                fontFeatures: tabular,
                fontWeight: FontWeight.w600,
                color: c.valid ? Tokens.ink : Tokens.ink3,
              ),
            ),
            Text(
              [
                taxModeLabels[d['tax_mode']],
                if (d['extra_cost'] != null)
                  '单价 ${money(d['price'] as String?)} + 附加 ${money(d['extra_cost'] as String?)}',
                if (d['lead_time_days'] != null) '${d['lead_time_days']} 天',
                scope ?? '范围未说明',
              ].whereType<String>().join(' · '),
              style: const TextStyle(fontSize: 11, color: Tokens.ink3),
            ),
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(spacing: 4, runSpacing: 4, children: tags),
            ],
          ],
        ),
      ),
    );
  }
}
