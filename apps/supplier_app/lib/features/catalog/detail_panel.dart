import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';
import '../../widgets/price_trend.dart';
import '../quotes/quote_form.dart';
import '../records/open_record.dart';
import 'catalog_page.dart';
import 'contacts.dart';

/// Side panel (or full page on phones) about one supplier or material:
/// what it is, its quotations and where it is used.
class CatalogDetail extends StatelessWidget {
  const CatalogDetail({
    super.key,
    required this.state,
    required this.type,
    required this.id,
    this.onClose,
  });
  final AppState state;
  final String type, id;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final record = state.store.get(type, id);
      if (record == null || record.deleted) {
        return const EmptyState(title: '这条记录已删除', body: '可以在 设置 › 已删除的记录 中恢复。');
      }
      final d = record.data;
      return Container(
        color: Tokens.surface,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    d['name']! as String,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    tooltip: '关闭',
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 18),
                  ),
              ],
            ),
            ...(type == 'supplier'
                ? _supplier(context, d)
                : _product(context, d)),
          ],
        ),
      );
    },
  );

  Widget _actions(BuildContext context, Map<String, Object?> prefill) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      OutlinedButton.icon(
        onPressed: () => showCatalogForm(context, state, type, id: id),
        icon: const Icon(Icons.edit_outlined, size: 16),
        label: const Text('编辑'),
      ),
      FilledButton.icon(
        onPressed: () => showQuoteForm(context, state, prefill: prefill),
        icon: const Icon(Icons.add, size: 16),
        label: const Text('新建报价'),
      ),
    ],
  );

  List<Widget> _supplier(BuildContext context, Map<String, Object?> d) {
    final store = state.store;
    final row = store.supplierRows(only: {id}).single;
    final quotes = store.quoteRows(supplierIds: {id}, limit: 20);
    final projects = {
      for (final r in store.quoteRows(supplierIds: {id}, limit: 500).rows)
        if (r.data['project_id'] case final String p) p: r.project,
    };
    return [
      _sub(
        [
          (d['aliases']! as List).join('、'),
          (d['categories']! as List).join('、'),
          d['address'] as String?,
        ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
      ),
      const SizedBox(height: 12),
      _actions(context, {'supplier_id': id}),
      const SizedBox(height: 16),
      _strip([
        ('报价', '${row.quotes}'),
        ('中标', '${row.awards}'),
        ('项目', '${row.projects}'),
        ('最近报价', row.lastQuotedOn ?? '—'),
      ]),
      _section(
        '联系人',
        trailing: TextButton(
          onPressed: () => showContactForm(context, state, id),
          child: const Text('添加'),
        ),
      ),
      for (final c in store.contactsOf(id))
        _line(
          c.data['name']! as String,
          [
            c.data['phone'],
            c.data['wechat'],
            c.data['email'],
          ].whereType<String>().join(' · '),
          onTap: () => showContactForm(context, state, id, id: c.id),
        ),
      if (row.contacts == 0) _empty('还没有联系人'),
      _section('最近报价 · 共 ${quotes.total} 条'),
      for (final q in quotes.rows)
        _line(
          [q.product, q.model].whereType<String>().join(' '),
          [q.data['quoted_on'], q.project].whereType<String>().join(' · '),
          trailing: _price(q.data),
          onTap: () => showQuoteForm(context, state, id: q.id),
        ),
      if (quotes.rows.isEmpty) _empty('还没有报价'),
      _section('参与的项目'),
      for (final e in projects.entries)
        _line(
          e.value ?? '项目',
          '',
          onTap: () => openRecord(context, state, 'project', e.key),
        ),
      if (projects.isEmpty) _empty('还没有项目报价'),
    ];
  }

  List<Widget> _product(BuildContext context, Map<String, Object?> d) {
    final store = state.store;
    final groups = store.compareQuotes(id);
    // The trend follows the comparable basis with the most quotes.
    final main = groups.isEmpty
        ? null
        : (groups.toList()
                ..sort((a, b) => b.rows.length.compareTo(a.rows.length)))
              .first;
    final history = main == null
        ? null
        : store.priceHistory(
            id,
            currency: main.currency,
            taxMode: main.taxMode,
            unit: main.unit,
          );
    final uses = store.relatedRecords('project_item.product_id', id, limit: 50);
    final attributes = (d['attributes'] as Map?)?.cast<String, String>();
    return [
      if ([d['brand'], d['model']].any((v) => v != null))
        MonoText([d['brand'], d['model']].whereType<String>().join(' · ')),
      _sub(
        [
          d['specification'],
          d['category'],
          '单位 ${d['unit']}',
        ].whereType<String>().join(' · '),
      ),
      if (attributes != null && attributes.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final e in attributes.entries)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Tokens.sunken,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${e.key} ${e.value}',
                  style: TextStyle(fontSize: 12, color: Tokens.ink2),
                ),
              ),
          ],
        ),
      ],
      const SizedBox(height: 12),
      _actions(context, {'product_id': id, 'unit_snapshot': d['unit']}),
      if (main != null) ...[
        _section(
          '价格走势 · ${main.currency} ${taxModeLabels[main.taxMode] ?? main.taxMode} · 每${main.unit}',
        ),
        if (main.rows.any((r) => r.data['quoted_on'] != null))
          PriceTrend(
            points: [
              for (final r in main.rows)
                if (r.data['quoted_on'] case final String day)
                  TrendPoint(
                    day,
                    r.comparisonPrice,
                    usable: r.valid,
                    lowest: r.lowest,
                    awarded: r.awarded,
                  ),
            ],
          ),
        if (history != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '历史 最低 ${money(history.min)} · 平均 ${money(history.average)} · 最高 ${money(history.max)}'
              '${history.lastDeal == null ? '' : ' · 最近成交 ${money(history.lastDeal)}'}',
              style: TextStyle(fontSize: 12, color: Tokens.ink2),
            ),
          ),
        _section('各家报价'),
        for (final r in main.rows)
          _line(
            state.store
                        .get('supplier', r.data['supplier_id']! as String)
                        ?.data['name']
                    as String? ??
                '未知供应商',
            [
              r.data['quoted_on'],
              if (r.lowest) '最低有效价',
              if (r.awarded) '已定标',
              if (!r.valid) '不可用',
            ].whereType<String>().join(' · '),
            trailing: Text(
              money(r.comparisonPrice),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontFeatures: tabular,
                color: r.lowest
                    ? Tokens.green
                    : (r.valid ? Tokens.ink : Tokens.ink3),
              ),
            ),
            onTap: () => showQuoteForm(context, state, id: r.id),
          ),
      ] else ...[
        _section('报价'),
        _empty('还没有报价'),
      ],
      _section('用到它的项目'),
      for (final u in uses.rows)
        _line(
          state.store.get('project', u['project_id']! as String)?.data['name']
                  as String? ??
              '项目',
          '${u['qty']} ${u['unit']}',
          onTap: () =>
              openRecord(context, state, 'project', u['project_id']! as String),
        ),
      if (uses.rows.isEmpty) _empty('还没有项目用到'),
    ];
  }

  Widget _sub(String text) => text.isEmpty
      ? const SizedBox()
      : Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(text, style: TextStyle(color: Tokens.ink2)),
        );

  Widget _strip(List<(String, String)> cells) => Container(
    decoration: BoxDecoration(
      border: Border.symmetric(horizontal: BorderSide(color: Tokens.rule)),
    ),
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      children: [
        for (final (label, value) in cells)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 12, color: Tokens.ink3)),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    fontFeatures: tabular,
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  Widget _section(String title, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.only(top: 18, bottom: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        ?trailing,
      ],
    ),
  );

  Widget _line(
    String title,
    String sub, {
    Widget? trailing,
    VoidCallback? onTap,
  }) => InkWell(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Tokens.rule)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, overflow: TextOverflow.ellipsis),
                if (sub.isNotEmpty)
                  Text(sub, style: TextStyle(fontSize: 12, color: Tokens.ink3)),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    ),
  );

  Widget _price(Map<String, Object?> q) => Text(
    '${money(priceOf(q), prefix: q['currency'] == 'CNY' ? '¥' : '${q['currency']} ')} / ${q['unit_snapshot']}',
    style: const TextStyle(fontWeight: FontWeight.w600, fontFeatures: tabular),
  );

  Widget _empty(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(text, style: TextStyle(color: Tokens.ink3)),
  );
}
