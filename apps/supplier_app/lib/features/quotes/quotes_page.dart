import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';
import 'compare_view.dart';
import 'quote_form.dart';

const _taxShort = {'included': '含税', 'excluded': '不含税', 'unknown': '口径未知'};

class QuotesPage extends StatefulWidget {
  const QuotesPage({super.key, required this.state});
  final AppState state;

  @override
  State<QuotesPage> createState() => _QuotesPageState();
}

class _QuotesPageState extends State<QuotesPage> {
  String query = '';
  String? comparing;
  Store get store => widget.state.store;

  List<String> get _words =>
      query.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  List<Hit> _quotes() {
    final words = query
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return store.listQuotations(limit: 300);
    return [
      for (final p in store.searchProducts(words, limit: 20))
        ...store.listQuotations(productId: p.id, limit: 50),
    ];
  }

  Future<void> _import() async {
    final file = await pickBytes(['xlsx']);
    if (file == null || !mounted) return;
    List<QuoteRowPlan> plans;
    try {
      plans = store.planQuotationImport(file.bytes);
    } on FormatException catch (e) {
      return toast(context, '无法读取 ${file.name}：${e.message}');
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ImportPreview(name: file.name, plans: plans),
    );
    if (confirmed != true || !mounted) return;
    late int saved;
    final err = widget.state.write(
      (s) => saved = s.applyQuotationImport(plans),
    );
    toast(context, err ?? '已写入 $saved 条报价');
  }

  Future<void> _export({bool blank = false}) async {
    final bytes = blank
        ? writeXlsx([
            SheetData('报价', [quoteColumns]),
          ])
        : store.exportQuotations();
    final saved = await saveBytes(
      blank ? '报价模板.xlsx' : '报价表-${today()}.xlsx',
      bytes,
      extensions: ['xlsx'],
    );
    if (saved && mounted) toast(context, blank ? '已保存空模板' : '已导出报价表');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.state,
    builder: (context, _) {
      if (comparing != null) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
          child: CompareView(
            state: widget.state,
            productId: comparing!,
            onClose: () => setState(() => comparing = null),
          ),
        );
      }
      final quotes = _quotes();
      final matches = _words.isEmpty
          ? const <Hit>[]
          : store.searchProducts(_words, limit: 6);
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                Text('报价查询', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(width: 16),
                OutlinedButton(onPressed: _import, child: const Text('导入报价表')),
                OutlinedButton(onPressed: _export, child: const Text('导出报价表')),
                TextButton(
                  onPressed: () => _export(blank: true),
                  child: const Text('空模板'),
                ),
                FilledButton.icon(
                  onPressed: () => showQuoteForm(context, widget.state),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新建报价'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: '按物料型号、名称、品牌或规格查找',
              ),
              onChanged: (v) => setState(() => query = v.trim()),
            ),
            if (matches.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('比价：', style: TextStyle(color: Tokens.ink2)),
                  for (final m in matches)
                    ActionChip(
                      avatar: const Icon(Icons.compare_arrows, size: 16),
                      label: Text(
                        [
                          m.data['name'],
                          m.data['model'],
                        ].whereType<String>().join(' '),
                      ),
                      onPressed: () => setState(() => comparing = m.id),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Expanded(
              child: quotes.isEmpty
                  ? EmptyState(
                      title: query.isEmpty ? '还没有报价' : '没有找到相关报价',
                      body: '可以逐条新建，也可以用报价模板在 Excel 里批量填写后导入。',
                    )
                  : Material(
                      color: Tokens.surface,
                      clipBehavior: Clip.antiAlias,
                      shape: RoundedRectangleBorder(
                        side: const BorderSide(color: Tokens.rule),
                        borderRadius: BorderRadius.circular(Tokens.radius),
                      ),
                      child: ListView.separated(
                        itemCount: quotes.length,
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (context, i) => _row(quotes[i]),
                      ),
                    ),
            ),
          ],
        ),
      );
    },
  );

  Widget _row(Hit h) {
    final q = h.data;
    final product = store.get('product', q['product_id']! as String)?.data;
    final supplier = store
        .get('supplier', q['supplier_id']! as String)
        ?.data['name'];
    final project = q['project_id'] == null
        ? null
        : store.get('project', q['project_id']! as String)?.data['name'];
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final expired =
        q['valid_until'] != null &&
        (q['valid_until']! as String).compareTo(today) < 0;
    return ListTile(
      minTileHeight: 56,
      title: Text(
        [product?['name'], product?['model']].whereType<String>().join('  '),
      ),
      subtitle: Text(
        [
          supplier,
          project,
          '报价 ${q['quoted_on'] ?? '日期未填'}',
          if (q['valid_until'] != null) '有效至 ${q['valid_until']}',
        ].whereType<String>().join(' · '),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${money(q['price'] as String?, prefix: q['currency'] == 'CNY' ? '¥' : '${q['currency']} ')} / ${q['unit_snapshot']}',
            style: const TextStyle(
              fontFeatures: tabular,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (expired)
            const HintTag(
              '已过期',
              icon: Icons.event_busy_outlined,
              tone: HintTone.error,
            )
          else
            Text(
              _taxShort[q['tax_mode']] ?? '',
              style: const TextStyle(fontSize: 12, color: Tokens.ink3),
            ),
        ],
      ),
      onTap: () => showQuoteForm(context, widget.state, id: h.id),
    );
  }
}

class _ImportPreview extends StatelessWidget {
  const _ImportPreview({required this.name, required this.plans});
  final String name;
  final List<QuoteRowPlan> plans;

  @override
  Widget build(BuildContext context) {
    int count(RowAction a) => plans.where((p) => p.action == a).length;
    final writes = count(RowAction.create) + count(RowAction.update);
    final attention = plans
        .where((p) => p.action == RowAction.error || p.changedSinceExport)
        .toList();
    return AlertDialog(
      title: Text('导入预览：$name'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '新增 ${count(RowAction.create)} · 更新 ${count(RowAction.update)} · 无变化 ${count(RowAction.unchanged)} · '
              '疑似重复（跳过）${count(RowAction.duplicate)} · 有问题 ${count(RowAction.error)}',
            ),
            if (attention.isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final p in attention)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          p.action == RowAction.error
                              ? Icons.error_outline
                              : Icons.history,
                          color: p.action == RowAction.error
                              ? Tokens.red
                              : Tokens.amber,
                          size: 18,
                        ),
                        title: Text('第 ${p.row} 行'),
                        subtitle: Text(p.error ?? '本机在导出后又改过这条报价，导入会覆盖本机的修改'),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: writes == 0 ? null : () => Navigator.pop(context, true),
          child: Text(writes == 0 ? '没有需要写入的行' : '确认导入（$writes 行）'),
        ),
      ],
    );
  }
}
