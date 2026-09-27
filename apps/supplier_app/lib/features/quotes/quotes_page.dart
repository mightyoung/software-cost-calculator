import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';
import '../ai/material_import_page.dart';
import 'compare_view.dart';
import 'quote_form.dart';

QuoteAttention _loadQuoteAttention(Store store) =>
    store.quoteAttention(limit: 50);

class QuotesPage extends StatefulWidget {
  const QuotesPage({super.key, required this.state});
  final AppState state;

  @override
  State<QuotesPage> createState() => _QuotesPageState();
}

class _QuotesPageState extends State<QuotesPage> {
  String query = '';
  var limit = pageSize;
  String? comparing;
  Store get store => widget.state.store;
  QuoteAttention? attention;
  bool attentionFailed = false;
  Timer? _attentionTimer;
  int _attentionRun = 0;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_refreshAttention);
    _loadAttention();
  }

  @override
  void didUpdateWidget(covariant QuotesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state == widget.state) return;
    oldWidget.state.removeListener(_refreshAttention);
    _attentionTimer?.cancel();
    attention = null;
    attentionFailed = false;
    widget.state.addListener(_refreshAttention);
    _loadAttention();
  }

  @override
  void dispose() {
    _attentionTimer?.cancel();
    _attentionRun++;
    widget.state.removeListener(_refreshAttention);
    super.dispose();
  }

  void _refreshAttention() {
    _attentionTimer?.cancel();
    _attentionTimer = Timer(const Duration(milliseconds: 150), _loadAttention);
  }

  Future<void> _loadAttention() async {
    final run = ++_attentionRun;
    try {
      final result = await store.inBackground(_loadQuoteAttention);
      if (mounted && run == _attentionRun) {
        setState(() {
          attention = result;
          attentionFailed = false;
        });
      }
    } catch (_) {
      if (mounted && run == _attentionRun) {
        setState(() {
          attention = null;
          attentionFailed = true;
        });
      }
    }
  }

  List<String> get _words =>
      query.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

  List<Hit> _quotes() {
    final words = query
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return store.listQuotations(limit: limit);
    return [
      for (final p in store.searchProducts(words, limit: 50))
        ...store.listQuotations(productId: p.id, limit: limit),
    ].take(limit).toList();
  }

  Future<void> _import() async {
    final file = await pickBytes(['xlsx']);
    if (file == null || !mounted) return;
    List<QuoteRowPlan> plans;
    try {
      plans = store.planQuotationImport(file.bytes);
    } on FormatException catch (e) {
      return toast(context, '无法读取 ${file.name}：${friendlyError(e.message)}');
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

  Future<void> _smartImport() async {
    final msg = await showMaterialImport(context, widget.state);
    if (msg != null && mounted) toast(context, msg);
  }

  Future<void> _showAttention() async {
    final details = attention;
    if (details == null) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('报价时效提醒'),
        content: SizedBox(
          width: MediaQuery.sizeOf(dialogContext).width < 640 ? null : 560,
          height: MediaQuery.sizeOf(dialogContext).height * .6,
          child: ListView(
            children: [
              Text('未来 30 天到期 · ${details.expiringCount} 条'),
              if (details.expiring.isEmpty)
                const ListTile(title: Text('暂无即将到期的报价')),
              for (final h in details.expiring)
                ListTile(
                  leading: const Icon(Icons.event_outlined),
                  title: Text(
                    '${store.get('product', h.data['product_id'] as String)?.data['name'] ?? '物料已删除'}',
                  ),
                  subtitle: Text(
                    '${store.get('supplier', h.data['supplier_id'] as String)?.data['name'] ?? '供应商已删除'}'
                    ' · 有效至 ${h.data['expires_on']}',
                  ),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    showQuoteForm(context, widget.state, id: h.id);
                  },
                ),
              const Divider(),
              Text('超过 90 天无新报价的物料 · ${details.staleProductCount} 种'),
              if (details.staleProducts.isEmpty)
                const ListTile(title: Text('暂无长期未更新的物料')),
              for (final h in details.staleProducts)
                ListTile(
                  leading: const Icon(Icons.history_outlined),
                  title: Text('${h.data['name']}'),
                  subtitle: Text('最近报价 ${h.data['last_quoted_on']}'),
                  onTap: () {
                    Navigator.pop(dialogContext);
                    setState(() => comparing = h.id);
                  },
                ),
              if (details.expiringCount > details.expiring.length ||
                  details.staleProductCount > details.staleProducts.length)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('每类仅显示最早的 50 条。'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
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
      final more = quotes.length >= limit;
      final matches = _words.isEmpty
          ? const <Hit>[]
          : store.searchProducts(_words, limit: 6);
      final activeAttention = attention;
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
                const SizedBox(width: 10),
                Text(
                  query.isEmpty
                      ? '共 ${store.recordCounts()['quotation']} 条'
                      : '找到 ${quotes.length}${more ? '+' : ''} 条',
                  style: const TextStyle(color: Tokens.ink3),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: _smartImport,
                  icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: const Text('智能导入'),
                ),
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
              onChanged: (v) => setState(() {
                query = v.trim();
                limit = pageSize;
              }),
            ),
            if (attentionFailed)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _loadAttention,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('时效提醒暂不可用，点击重试'),
                ),
              ),
            if (activeAttention != null &&
                activeAttention.expiringCount +
                        activeAttention.staleProductCount >
                    0) ...[
              const SizedBox(height: 8),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 4,
                children: [
                  const Icon(
                    Icons.notifications_active_outlined,
                    size: 18,
                    color: Tokens.accent,
                  ),
                  Text(
                    '30 天内到期 ${activeAttention.expiringCount} 条 · '
                    '90 天无新报价 ${activeAttention.staleProductCount} 种',
                  ),
                  TextButton(
                    onPressed: _showAttention,
                    child: const Text('查看提醒'),
                  ),
                ],
              ),
            ],
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
                      body: '可以逐条新建、用"智能导入"粘贴供应商发来的报价，或用报价模板在 Excel 里批量填写后导入。',
                    )
                  : Material(
                      color: Tokens.surface,
                      clipBehavior: Clip.antiAlias,
                      shape: RoundedRectangleBorder(
                        side: const BorderSide(color: Tokens.rule),
                        borderRadius: BorderRadius.circular(Tokens.radius),
                      ),
                      child: ListView.separated(
                        itemCount: quotes.length + (more ? 1 : 0),
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (context, i) => i == quotes.length
                            ? MoreRow(
                                shown: quotes.length,
                                onMore: () => setState(() => limit += pageSize),
                              )
                            : _row(quotes[i]),
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
              taxModeLabels[q['tax_mode']] ?? '',
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
