import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/data_grid.dart';
import '../../widgets/deletion.dart';
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
  var filter = QuoteFilter.all;
  String? projectId;
  GridSort sort = (column: 4, ascending: false);
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

  /// Grid column → database sort; null for columns that do not sort.
  static const _sortBy = {
    0: QuoteSort.product,
    1: QuoteSort.supplier,
    3: QuoteSort.price,
    4: QuoteSort.quotedOn,
  };

  QuotePage _quotes() {
    final words = _words;
    return store.quoteRows(
      filter: filter,
      projectId: projectId,
      productIds: words.isEmpty
          ? null
          : {for (final h in store.searchProducts(words, limit: 500)) h.id},
      supplierIds: words.isEmpty
          ? null
          : {
              for (final h in store.searchByName('supplier', query, limit: 500))
                h.id,
            },
      sort: _sortBy[sort.column]!,
      descending: !sort.ascending,
      limit: limit,
    );
  }

  static const _issueLabels = {
    QuoteIssue.expired: ('已过期', HintTone.error),
    QuoteIssue.stale: ('超 90 天未更新', HintTone.warning),
    QuoteIssue.informal: ('口头或参考价', HintTone.warning),
    QuoteIssue.taxUnknown: ('含税口径未知', HintTone.warning),
    QuoteIssue.future: ('报价日期在未来', HintTone.warning),
    QuoteIssue.undated: ('未填报价日期', HintTone.warning),
    QuoteIssue.supplierDeleted: ('供应商已删除', HintTone.error),
  };

  List<GridColumn<QuoteRow>> get _columns => [
    GridColumn(
      '物料 / 型号',
      flex: 3,
      value: (r) => r.product,
      cell: (r) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.product, overflow: TextOverflow.ellipsis),
          if (r.model != null) MonoText(r.model!),
        ],
      ),
    ),
    GridColumn('供应商', flex: 2, value: (r) => r.supplier),
    GridColumn(
      '项目',
      flex: 2,
      sortable: false,
      value: (r) => r.project ?? '通用报价',
    ),
    GridColumn(
      '单价',
      width: 150,
      numeric: true,
      value: (r) => Num(priceOf(r.data)),
      cell: (r) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${money(priceOf(r.data), prefix: r.data['currency'] == 'CNY' ? '¥' : '${r.data['currency']} ')} / ${r.data['unit_snapshot']}',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              fontFeatures: tabular,
            ),
          ),
          Text(
            taxModeLabels[r.data['tax_mode']] ?? '',
            style: TextStyle(fontSize: 12, color: Tokens.ink3),
          ),
        ],
      ),
    ),
    GridColumn('报价日期', width: 104, value: (r) => r.data['quoted_on']),
    GridColumn(
      '有效期至',
      width: 104,
      sortable: false,
      value: (r) => r.data['valid_until'],
    ),
    GridColumn(
      '状态',
      width: 150,
      sortable: false,
      value: (r) => r.awarded
          ? '已定标'
          : r.issues.isEmpty
          ? '可用'
          : _issueLabels[r.issues.first]!.$1,
      cell: (r) => r.awarded
          ? const HintTag(
              '已定标',
              icon: Icons.verified_outlined,
              tone: HintTone.success,
            )
          : r.issues.isEmpty
          ? Text('可用', style: TextStyle(color: Tokens.ink3))
          : HintTag(
              _issueLabels[r.issues.first]!.$1,
              icon: Icons.block,
              tone: _issueLabels[r.issues.first]!.$2,
            ),
    ),
  ];

  Future<void> _exportRows(List<QuoteRow> rows) async {
    final saved = await saveBytes(
      '报价-${today()}.xlsx',
      gridToXlsx('报价', _columns, rows),
      extensions: ['xlsx'],
    );
    if (saved && mounted) toast(context, '已导出 ${rows.length} 条报价');
  }

  Future<void> _import() async {
    final file = await pickBytes(['xlsx']);
    if (file == null || !mounted) return;
    List<QuoteRowPlan>? plans;
    String? problem;
    try {
      plans = store.planQuotationImport(file.bytes);
    } on FormatException catch (e) {
      problem = e.message;
    }
    if (plans == null) {
      // Not our template: read it as an ordinary quote or selection table
      // and review it like a smart import (new suppliers and materials).
      final offers = _tableOffers(file.bytes);
      if (offers == null || offers.isEmpty) {
        return toast(context, '无法读取 ${file.name}：${friendlyError(problem!)}');
      }
      final msg = await showMaterialImport(
        context,
        widget.state,
        table: (name: file.name, bytes: file.bytes, offers: offers),
      );
      if (msg != null && mounted) toast(context, msg);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => _ImportPreview(name: file.name, plans: plans!),
    );
    if (confirmed != true || !mounted) return;
    late int saved;
    final err = widget.state.write(
      (s) => saved = s.applyQuotationImport(plans!),
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
      final page = _quotes();
      final quotes = page.rows;
      final more = quotes.length < page.total;
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
                Text('报价', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(width: 10),
                Text(
                  query.isEmpty &&
                          filter == QuoteFilter.all &&
                          projectId == null
                      ? '共 ${page.total} 条'
                      : '找到 ${page.total} 条',
                  style: TextStyle(color: Tokens.ink3),
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
                hintText: '物料、型号、供应商或拼音首字母',
              ),
              onChanged: (v) => setState(() {
                query = v.trim();
                limit = pageSize;
              }),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final (f, label) in [
                  (QuoteFilter.all, '全部'),
                  (QuoteFilter.usable, '可用'),
                  (QuoteFilter.expired, '已过期'),
                  (QuoteFilter.informal, '口头参考'),
                  (QuoteFilter.awarded, '已定标'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: filter == f,
                    onSelected: (_) => setState(() {
                      filter = f;
                      limit = pageSize;
                    }),
                  ),
                const SizedBox(width: 10),
                DropdownButton<String?>(
                  value: projectId,
                  hint: const Text('全部项目'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('全部项目')),
                    for (final h in store.searchByName(
                      'project',
                      '',
                      limit: 500,
                    ))
                      DropdownMenuItem(
                        value: h.id,
                        child: Text(h.data['name']! as String),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    projectId = v;
                    limit = pageSize;
                  }),
                ),
              ],
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
                  Icon(
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
                  Text('比价：', style: TextStyle(color: Tokens.ink2)),
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
                  : DataGrid<QuoteRow>(
                      rows: quotes,
                      columns: _columns,
                      id: (r) => r.id,
                      sort: sort,
                      onSort: (next) => setState(() {
                        // Unsortable columns keep the current order.
                        if (_sortBy.containsKey(next.column)) sort = next;
                        limit = pageSize;
                      }),
                      onOpen: (r) =>
                          showQuoteForm(context, widget.state, id: r.id),
                      footer: more
                          ? MoreRow(
                              shown: quotes.length,
                              onMore: () => setState(() => limit += pageSize),
                            )
                          : null,
                      bulkActions: (selected, clear) => [
                        TextButton.icon(
                          onPressed: () => _exportRows(selected),
                          icon: const Icon(
                            Icons.file_download_outlined,
                            size: 18,
                          ),
                          label: const Text('导出选中'),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Tokens.red,
                          ),
                          onPressed: () async {
                            await deleteManyWithUndo(
                              context,
                              widget.state,
                              type: 'quotation',
                              ids: [for (final r in selected) r.id],
                            );
                            clear();
                          },
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('删除'),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      );
    },
  );
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

List<Offer>? _tableOffers(Uint8List bytes) {
  try {
    return offersFromWorkbook(readXlsx(bytes));
  } on FormatException {
    return null;
  }
}
