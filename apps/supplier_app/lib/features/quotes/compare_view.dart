import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';
import '../inquiries/award_dialog.dart';
import 'quote_extras.dart';
import 'quote_form.dart';
import '../../widgets/price_trend.dart';

const _issueText = {
  QuoteIssue.expired: '已过期',
  QuoteIssue.future: '报价日期在未来',
  QuoteIssue.undated: '未填报价日期',
  QuoteIssue.stale: '超过 90 天且未写有效期',
  QuoteIssue.taxUnknown: '含税口径未知',
  QuoteIssue.supplierDeleted: '供应商已删除',
  QuoteIssue.supplierDisabled: '供应商已停用',
  QuoteIssue.informal: '口头或参考价',
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
              icon: const AppIcon(Icons.arrow_back, size: 18),
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
        Padding(
          padding: EdgeInsets.fromLTRB(0, 4, 0, 10),
          child: Text(
            '同币种报价按含税价及物料基准单位比较；跨税口径需税率，跨单位需在物料中配置换算。无法换算的报价单列。',
            style: TextStyle(color: Tokens.ink2),
          ),
        ),
        Expanded(
          child: groups.isEmpty
              ? const EmptyState(title: '这个物料还没有报价', body: '录入或导入报价后即可比价。')
              : LayoutBuilder(
                  builder: (context, size) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: size.maxWidth.clamp(
                        1120 * MediaQuery.textScalerOf(context).scale(1),
                        double.infinity,
                      ),
                      child: ListView(
                        children: [
                          for (final g in groups) ...[
                            _GroupHeader(
                              group: g,
                              history: store.priceHistory(
                                productId,
                                currency: g.currency,
                                taxMode: g.taxMode,
                                unit: g.unit,
                                forCompareGroup: true,
                              ),
                            ),
                            _columnsHeader(),
                            for (final r in g.rows) _row(context, r, g),
                            const SizedBox(height: 16),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// Column widths shared by the header and the rows (null = flexible).
  static const _cols = <(String, double?, bool)>[
    ('供应商', null, false),
    ('比较价', 150, true),
    ('报价日期', 100, false),
    ('有效期至', 100, false),
    ('起订', 64, true),
    ('交期', 64, true),
    ('质保', 64, true),
    ('价格包含', null, false),
    ('状态', null, false),
    ('', 76, false),
  ];

  static Widget _cell(int i, Widget child) {
    final (_, width, numeric) = _cols[i];
    final aligned = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Align(
        alignment: numeric ? Alignment.centerRight : Alignment.centerLeft,
        child: child,
      ),
    );
    return width == null
        ? Expanded(flex: i == 0 ? 3 : 2, child: aligned)
        : SizedBox(width: width, child: aligned);
  }

  Widget _columnsHeader() => Container(
    height: 34,
    decoration: BoxDecoration(
      color: Tokens.groupRow,
      border: Border(
        left: BorderSide(color: Tokens.rule),
        right: BorderSide(color: Tokens.rule),
        bottom: BorderSide(color: Tokens.rule),
      ),
    ),
    child: Row(
      children: [
        for (final (i, (label, _, _)) in _cols.indexed)
          _cell(
            i,
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Tokens.ink2,
              ),
            ),
          ),
      ],
    ),
  );

  Widget _row(BuildContext context, CompareRow r, CompareGroup g) {
    final store = state.store;
    final history = store.priceHistory(
      productId,
      currency: g.currency,
      taxMode: g.taxMode,
      unit: g.unit,
      forCompareGroup: true,
    );
    final deviation = history != null && history.count >= 3
        ? history.deviationPercent(r.comparisonPrice)
        : null;
    final supplier =
        store.get('supplier', r.data['supplier_id']! as String)?.data['name']
            as String?;
    final project = r.data['project_id'] == null
        ? null
        : store.get('project', r.data['project_id']! as String)?.data['name']
              as String?;
    final muted = !r.valid;
    final ink = muted ? Tokens.ink3 : Tokens.ink;
    final small = TextStyle(fontSize: 12, color: Tokens.ink3);
    String? n(Object? v, String unit) => v == null ? null : '$v $unit';
    return InkWell(
      onTap: () => showQuoteForm(context, state, id: r.id),
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: r.lowest ? Tokens.greenBg : Tokens.surface,
          border: Border(
            left: BorderSide(color: Tokens.rule),
            right: BorderSide(color: Tokens.rule),
            bottom: BorderSide(color: Tokens.rule),
          ),
        ),
        child: Row(
          children: [
            _cell(
              0,
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    supplier ?? '未知供应商',
                    style: TextStyle(fontWeight: FontWeight.w500, color: ink),
                  ),
                  if (project != null) Text(project, style: small),
                ],
              ),
            ),
            _cell(
              1,
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    money(r.comparisonPrice),
                    style: TextStyle(
                      fontFeatures: tabular,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                      color: r.lowest ? Tokens.green : ink,
                      decoration: muted ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (r.converted)
                    Text(
                      '原 ${money(r.price)} / ${r.data['unit_snapshot']}',
                      style: small,
                    ),
                  if (r.awarded)
                    Text(
                      '报价 ${money(r.data['price'] as String?)}',
                      style: small,
                    ),
                  if (r.data['price_tiers'] case final List tiers)
                    Tooltip(
                      message: [
                        for (final t in tiers.cast<Map>())
                          '≥ ${t['min_qty']} ${r.data['unit_snapshot']}：${money(t['price'] as String)}',
                      ].join('\n'),
                      child: Text(
                        '阶梯价 ${tiers.length} 档',
                        style: small.copyWith(color: Tokens.accentDeep),
                      ),
                    ),
                ],
              ),
            ),
            _cell(
              2,
              Text(
                r.data['quoted_on'] as String? ?? '—',
                style: TextStyle(color: ink),
              ),
            ),
            _cell(
              3,
              Text(
                r.data['valid_until'] as String? ?? '—',
                style: TextStyle(color: ink),
              ),
            ),
            _cell(
              4,
              Text(
                '${r.data['min_qty']}',
                style: TextStyle(color: ink, fontFeatures: tabular),
              ),
            ),
            _cell(
              5,
              Text(
                n(r.data['lead_time_days'], '天') ?? '—',
                style: TextStyle(color: ink),
              ),
            ),
            _cell(
              6,
              Text(
                n(r.data['warranty_months'], '月') ?? '—',
                style: TextStyle(color: ink),
              ),
            ),
            _cell(
              7,
              Text(
                [
                  scopeText(r.data['includes']) ?? '未说明',
                  if (r.data['extra_cost'] != null)
                    '另加 ${money(r.data['extra_cost'] as String?)}',
                ].join(' · '),
                style: TextStyle(fontSize: 12, color: ink),
              ),
            ),
            _cell(
              8,
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  if (r.lowest)
                    const HintTag(
                      '最低有效价',
                      icon: Icons.south,
                      tone: HintTone.success,
                    ),
                  if (r.awarded)
                    const HintTag(
                      '已定标',
                      icon: Icons.verified_outlined,
                      tone: HintTone.success,
                    ),
                  for (final i in r.issues)
                    HintTag(
                      _issueText[i]!,
                      icon: Icons.block,
                      tone: i == QuoteIssue.expired
                          ? HintTone.error
                          : HintTone.warning,
                    ),
                  if (deviation != null &&
                      deviation.abs() >= historyWarnPercent)
                    HintTag(
                      '比均价 ${deviation > 0 ? '+' : ''}$deviation%',
                      icon: Icons.history,
                    ),
                ],
              ),
            ),
            _cell(
              9,
              !r.valid || r.awarded || r.data['project_id'] == null
                  ? const SizedBox()
                  : TextButton(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        visualDensity: VisualDensity.compact,
                      ),
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
  Widget build(BuildContext context) {
    final dated = [
      for (final r in group.rows)
        if (r.data['quoted_on'] case final String day)
          TrendPoint(
            day,
            r.comparisonPrice,
            usable: r.valid,
            lowest: r.lowest,
            awarded: r.awarded,
          ),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Tokens.sunken,
        border: Border.all(color: Tokens.rule),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Tokens.radius),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              [
                '${group.currency} · ${taxModeLabels[group.taxMode] ?? group.taxMode}${group.rows.any((r) => r.converted) ? '（含换算）' : ''} · 单位 ${group.unit} · ${group.rows.length} 条报价',
                if (history case final h?)
                  '历史 最低 ${money(h.min)} · 平均 ${money(h.average)} · 最高 ${money(h.max)}'
                      '${h.lastDeal == null ? '' : ' · 最近成交 ${money(h.lastDeal)}'}',
              ].join('\n'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Tokens.ink2,
                height: 1.7,
              ),
            ),
          ),
          if (dated.length >= 2)
            SizedBox(width: 340, child: PriceTrend(points: dated, height: 96)),
        ],
      ),
    );
  }
}
