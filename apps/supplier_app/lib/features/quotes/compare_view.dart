import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';
import '../inquiries/award_dialog.dart';
import 'quote_extras.dart';
import 'quote_form.dart';

const _issueText = {
  QuoteIssue.expired: '已过期',
  QuoteIssue.future: '报价日期在未来',
  QuoteIssue.undated: '未填报价日期',
  QuoteIssue.stale: '超过 90 天且未写有效期',
  QuoteIssue.taxUnknown: '含税口径未知',
  QuoteIssue.supplierDeleted: '供应商已删除',
};

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
                      _GroupHeader(
                        group: g,
                        history: store.priceHistory(
                          productId,
                          currency: g.currency,
                          taxMode: g.taxMode,
                          unit: g.unit,
                        ),
                      ),
                      for (final r in g.rows) _row(context, r, g),
                      const SizedBox(height: 14),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, CompareRow r, CompareGroup g) {
    final history = state.store.priceHistory(
      productId,
      currency: g.currency,
      taxMode: g.taxMode,
      unit: g.unit,
    );
    final deviation = history != null && history.count >= 3
        ? history.deviationPercent(r.price)
        : null;
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
                  Text(
                    [
                      scopeText(r.data['includes']) ?? '范围未说明',
                      if (r.data['extra_cost'] != null)
                        '另有附加费用 ${money(r.data['extra_cost'] as String?)}',
                      if (r.awarded)
                        '已定标，成交价 ${money(r.data['deal_price'] as String?)}'
                            '（报价 ${money(r.data['price'] as String?)}）',
                    ].join(' · '),
                    style: const TextStyle(fontSize: 12, color: Tokens.ink3),
                  ),
                ],
              ),
            ),
            if (deviation != null && deviation.abs() >= historyWarnPercent)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: HintTag(
                  '比均价 ${deviation > 0 ? '+' : ''}$deviation%',
                  icon: Icons.history,
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
            SizedBox(
              width: 64,
              child: !r.valid || r.awarded || r.data['project_id'] == null
                  ? null
                  : Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: TextButton(
                        onPressed: () => showAwardDialog(
                          context,
                          state,
                          itemId: budgetLineFor(state.store, r.data),
                          choices: [
                            (
                              quotationId: r.id,
                              label: quoteLabel(state.store, r.data),
                            ),
                          ],
                        ),
                        child: const Text('定标'),
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
  const _GroupHeader({required this.group, this.history});
  final CompareGroup group;
  final PriceHistory? history;

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
      [
        '${group.currency} · ${taxModeLabels[group.taxMode] ?? group.taxMode} · 单位 ${group.unit} · ${group.rows.length} 条报价',
        if (history case final h?)
          '历史 最低 ${money(h.min)} · 平均 ${money(h.average)} · 最高 ${money(h.max)}'
              '${h.lastDeal == null ? '' : ' · 最近成交 ${money(h.lastDeal)}'}',
      ].join('    '),
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Tokens.ink2,
      ),
    ),
  );
}
