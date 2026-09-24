import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';
import 'quote_form.dart';

const _issueText = {
  QuoteIssue.expired: '已过期',
  QuoteIssue.future: '报价日期在未来',
  QuoteIssue.undated: '未填报价日期',
  QuoteIssue.stale: '超过 90 天且未写有效期',
  QuoteIssue.taxUnknown: '含税口径未知',
  QuoteIssue.supplierDeleted: '供应商已删除',
};

const _taxText = {'included': '含税', 'excluded': '不含税', 'unknown': '口径未知'};

/// All quotations of one material, grouped by comparable basis.
class CompareView extends StatelessWidget {
  const CompareView({
    super.key,
    required this.state,
    required this.productId,
    required this.onClose,
  });
  final AppState state;
  final String productId;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final store = state.store;
    final product = store.get('product', productId)?.data;
    final groups = store.compareQuotes(productId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            TextButton.icon(
              onPressed: onClose,
              icon: const Icon(Icons.arrow_back, size: 18),
              label: const Text('返回报价列表'),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '比价：${[product?['name'], product?['model']].whereType<String>().join(' ')}',
                style: Theme.of(context).textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(0, 4, 0, 10),
          child: Text(
            '只有币种、含税口径和单位都相同的报价才放在一起比较。灰色的报价不参与"最低有效价"，右侧写明了原因。',
            style: TextStyle(color: Tokens.ink2),
          ),
        ),
        Expanded(
          child: groups.isEmpty
              ? const EmptyState(title: '这个物料还没有报价', body: '录入或导入报价后即可比价。')
              : ListView(
                  children: [
                    for (final g in groups) ...[
                      _GroupHeader(group: g),
                      for (final r in g.rows) _row(context, r),
                      const SizedBox(height: 14),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, CompareRow r) {
    final store = state.store;
    final supplier =
        store.get('supplier', r.data['supplier_id']! as String)?.data['name']
            as String?;
    final project = r.data['project_id'] == null
        ? null
        : store.get('project', r.data['project_id']! as String)?.data['name']
              as String?;
    final muted = !r.valid;
    return InkWell(
      onTap: () => showQuoteForm(context, state, id: r.id),
      child: Container(
        decoration: BoxDecoration(
          color: r.lowest ? Tokens.accentTint : Tokens.surface,
          border: const Border(
            left: BorderSide(color: Tokens.rule),
            right: BorderSide(color: Tokens.rule),
            bottom: BorderSide(color: Tokens.rule),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    supplier ?? '未知供应商',
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      color: muted ? Tokens.ink3 : Tokens.ink,
                    ),
                  ),
                  Text(
                    [
                      '报价 ${r.data['quoted_on'] ?? '未填'}',
                      if (r.data['valid_until'] != null)
                        '有效至 ${r.data['valid_until']}',
                      if (r.data['min_qty'] != '1') '起订 ${r.data['min_qty']}',
                      ?project,
                    ].join(' · '),
                    style: const TextStyle(fontSize: 12, color: Tokens.ink3),
                  ),
                ],
              ),
            ),
            if (r.lowest)
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: Text(
                  '最低有效价',
                  style: TextStyle(
                    fontSize: 12,
                    color: Tokens.accentDeep,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            if (muted)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Wrap(
                  spacing: 4,
                  children: [
                    for (final i in r.issues)
                      HintTag(
                        _issueText[i]!,
                        icon: Icons.block,
                        tone: i == QuoteIssue.expired
                            ? HintTone.error
                            : HintTone.warning,
                      ),
                  ],
                ),
              ),
            SizedBox(
              width: 120,
              child: Text(
                money(r.price),
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontFeatures: tabular,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  color: muted ? Tokens.ink3 : Tokens.ink,
                  decoration: muted ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.group});
  final CompareGroup group;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: Tokens.sunken,
      border: Border.all(color: Tokens.rule),
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(Tokens.radius),
      ),
    ),
    child: Text(
      '${group.currency} · ${_taxText[group.taxMode] ?? group.taxMode} · 单位 ${group.unit} · ${group.rows.length} 条报价',
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Tokens.ink2,
      ),
    ),
  );
}
