import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../platform/cjk_font.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';
import '../ai/list_to_project.dart';
import '../ai/material_import_page.dart';
import '../inquiries/project_inquiries.dart';
import '../exchange/lan_push_page.dart';
import '../quotes/quote_form.dart';
import '../spec/spec_request_list.dart';
import 'budget_table.dart';
import 'item_dialogs.dart';
import 'project_form.dart';
import 'refresh_dialog.dart';

enum _Tab { budget, inquiries, specs, quotes, changes }

class ProjectDetail extends StatefulWidget {
  const ProjectDetail({
    super.key,
    required this.state,
    required this.projectId,
    this.compact = false,
  });
  final AppState state;
  final String projectId;
  final bool compact;

  @override
  State<ProjectDetail> createState() => _ProjectDetailState();
}

class _ProjectDetailState extends State<ProjectDetail> {
  var tab = _Tab.budget;
  AppState get state => widget.state;

  Future<void> _export(String kind, Map<String, Object?> p) async {
    final store = state.store;
    if (kind.endsWith('_pdf')) return _exportPdf(kind, p);
    final (name, bytes) = switch (kind) {
      'quote' => ('项目报价单', store.exportQuoteSheet(widget.projectId)),
      'budget' => ('成本预算表', store.exportCostBudget(widget.projectId)),
      _ => ('询价清单', store.exportInquiryList(widget.projectId)),
    };
    final saved = await saveBytes(
      '$name-${p['name']}-${today()}.xlsx',
      bytes,
      extensions: ['xlsx'],
    );
    if (saved && mounted) toast(context, '已导出$name');
  }

  Future<void> _exportPdf(String kind, Map<String, Object?> p) async {
    final font = await cjkFont();
    if (!mounted) return;
    if (font == null) {
      return toast(context, '本机没有找到可嵌入 PDF 的中文字体，请改用 Excel 导出');
    }
    final quote = kind == 'quote_pdf';
    final name = quote ? '项目报价单' : '成本预算表';
    final bytes = quote
        ? await state.store.quoteSheetPdf(widget.projectId, font)
        : await state.store.costBudgetPdf(widget.projectId, font);
    final saved = await saveBytes(
      '$name-${p['name']}-${today()}.pdf',
      bytes,
      extensions: ['pdf'],
    );
    if (saved && mounted) toast(context, '已导出$name PDF');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final record = state.store.get('project', widget.projectId);
      if (record == null || record.deleted) {
        return const EmptyState(title: '项目已删除', body: '这个项目已在本机或其他设备上删除。');
      }
      final p = record.data;
      final b = state.store.budget(widget.projectId);
      final pad = widget.compact ? 16.0 : 24.0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(pad, widget.compact ? 0 : 18, pad, 0),
            child: _Header(
              project: p,
              budget: b,
              compact: widget.compact,
              onEdit: () =>
                  showProjectForm(context, state, id: widget.projectId),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: pad, vertical: 10),
            child: _Toolbar(
              tab: tab,
              compact: widget.compact,
              onTab: (t) => setState(() => tab = t),
              onEdit: () =>
                  showProjectForm(context, state, id: widget.projectId),
              onDelete: () async {
                final route = ModalRoute.of(context);
                if (await deleteProject(context, state, widget.projectId) &&
                    context.mounted &&
                    route != null &&
                    !route.isFirst) {
                  Navigator.of(context).pop();
                }
              },
              onExport: (k) => _export(k, p),
              onFromList: () => showListToProject(context, state),
              onImport: () async {
                final msg = await showMaterialImport(
                  context,
                  state,
                  projectId: widget.projectId,
                );
                if (msg != null && context.mounted) toast(context, msg);
              },
              onAdd: () => showAddItems(context, state, widget.projectId),
              onRefresh: () =>
                  showRefreshPrices(context, state, widget.projectId),
              onPush: () => showLanPush(
                context,
                state,
                chosen: {
                  'project': {widget.projectId},
                },
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: switch (tab) {
                _Tab.budget => BudgetTable(
                  state: state,
                  projectId: widget.projectId,
                  budget: b,
                  compact: widget.compact,
                ),
                _Tab.inquiries => ProjectInquiries(
                  state: state,
                  projectId: widget.projectId,
                ),
                _Tab.specs => SpecRequestList(
                  state: state,
                  projectId: widget.projectId,
                ),
                _Tab.quotes => _ProjectQuotes(
                  state: state,
                  projectId: widget.projectId,
                ),
                _Tab.changes => _Changes(
                  store: state.store,
                  projectId: widget.projectId,
                ),
              },
            ),
          ),
          if (tab == _Tab.budget)
            BudgetTotals(
              budget: b,
              compact: widget.compact,
              margin: pad,
              onAdd: widget.compact
                  ? () => showAddItems(context, state, widget.projectId)
                  : null,
            ),
        ],
      );
    },
  );
}

class _Header extends StatelessWidget {
  const _Header({
    required this.project,
    required this.budget,
    required this.compact,
    required this.onEdit,
  });
  final Map<String, Object?> project;
  final Budget budget;
  final bool compact;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final p = project;
    final contract = p['contract_amount'] as String?;
    final meta = [
      p['customer'],
      if (p['leader'] != null) '负责人 ${p['leader']}',
      if (p['contract_no'] != null) '合同号 ${p['contract_no']}',
      '${p['currency']} ${p['tax_mode'] == 'included' ? '含税' : '不含税'}',
    ].whereType<String>().join(' · ');
    final contractPct = contract == null
        ? null
        : percent(budget.cost, contract);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            MonoText(p['code']! as String),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              decoration: BoxDecoration(
                color: Tokens.accentTint,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                statusLabels[p['status']] ?? '',
                style: TextStyle(fontSize: 12, color: Tokens.accentDeep),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Flexible(
              child: Text(
                p['name']! as String,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: '编辑项目',
              onPressed: onEdit,
              icon: const AppIcon(Icons.edit_outlined, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(meta, style: TextStyle(fontSize: 13, color: Tokens.ink2)),
        const SizedBox(height: 14),
        // Preserve readable amounts and warnings on touch-width screens.
        LedgerStrip(
          dense: compact,
          columns: compact ? 2 : null,
          cells: [
            LedgerCell(
              compact ? '合同' : '合同金额',
              contract == null ? '未填' : yuan(contract),
              dense: compact,
            ),
            LedgerCell(
              compact ? '成本' : '成本合计',
              yuan(budget.cost),
              alert: budget.contractWarning
                  ? (compact ? '达合同 $contractPct' : '已达合同金额 $contractPct')
                  : null,
              dense: compact,
            ),
            LedgerCell(
              compact ? '报价' : '对外报价',
              yuan(budget.price),
              note: '加价 ${p['markup_rate']}%',
              dense: compact,
            ),
            LedgerCell(
              '毛利',
              yuan(budget.margin),
              note: percent(budget.margin, budget.price),
              dense: compact,
            ),
          ],
        ),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.tab,
    required this.compact,
    required this.onTab,
    required this.onEdit,
    required this.onDelete,
    required this.onExport,
    required this.onAdd,
    required this.onFromList,
    required this.onImport,
    required this.onRefresh,
    required this.onPush,
  });
  final _Tab tab;
  final bool compact;
  final ValueChanged<_Tab> onTab;
  final VoidCallback onEdit,
      onDelete,
      onAdd,
      onFromList,
      onImport,
      onRefresh,
      onPush;
  final ValueChanged<String> onExport;

  static const _exports = [
    ('quote', '导出项目报价单（给客户）'),
    ('quote_pdf', '导出项目报价单 PDF'),
    ('budget', '导出成本预算表（内部）'),
    ('budget_pdf', '导出成本预算表 PDF'),
    ('inquiry', '导出待询价清单（给供应商）'),
  ];

  @override
  Widget build(BuildContext context) {
    Widget tabButton(_Tab t, String label) => Semantics(
      selected: t == tab,
      button: true,
      child: InkWell(
        onTap: () => onTab(t),
        focusColor: Tokens.accentTint,
        child: Container(
          constraints: BoxConstraints(minHeight: compact ? 48 : 40),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(vertical: 6),
          margin: const EdgeInsets.only(right: 20),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: t == tab ? Tokens.accent : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: t == tab ? Tokens.accentDeep : Tokens.ink2,
              fontWeight: t == tab ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
    final tabs = [
      tabButton(_Tab.budget, '成本预算'),
      tabButton(_Tab.inquiries, '询价单'),
      tabButton(_Tab.specs, '技术要求'),
      tabButton(_Tab.quotes, '报价记录'),
      tabButton(_Tab.changes, '变更记录'),
    ];
    if (compact) {
      // Phones: actions live in one overflow menu; "添加" sits by the totals.
      return Row(
        children: [
          // Five tabs do not fit a phone's width: they scroll sideways.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: tabs),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            icon: const AppIcon(Icons.more_vert),
            onSelected: (v) => switch (v) {
              'edit' => onEdit(),
              'list' => onFromList(),
              'import' => onImport(),
              'refresh' => onRefresh(),
              'push' => onPush(),
              'delete' => onDelete(),
              _ => onExport(v),
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('编辑项目')),
              const PopupMenuItem(
                value: 'import',
                child: Text('导入报价或粘贴 Excel'),
              ),
              const PopupMenuItem(value: 'refresh', child: Text('按最优价刷新')),
              const PopupMenuItem(value: 'list', child: Text('从清单生成新项目')),
              const PopupMenuItem(value: 'push', child: Text('推送到局域网设备')),
              for (final (value, label) in _exports)
                PopupMenuItem(value: value, child: Text(label)),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'delete',
                child: Text('删除项目', style: TextStyle(color: Tokens.red)),
              ),
            ],
          ),
        ],
      );
    }
    // Actions wrap under the tabs when the detail pane is narrow.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...tabs,
        const SizedBox(width: 16),
        Expanded(
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onImport,
                icon: const AppIcon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('导入报价或粘贴 Excel'),
              ),
              OutlinedButton.icon(
                onPressed: onRefresh,
                icon: const AppIcon(Icons.price_change_outlined, size: 18),
                label: const Text('刷新价格'),
              ),
              MenuAnchor(
                menuChildren: [
                  MenuItemButton(
                    onPressed: onEdit,
                    leadingIcon: const AppIcon(Icons.edit_outlined, size: 18),
                    child: const Text('编辑项目'),
                  ),
                  MenuItemButton(
                    onPressed: onPush,
                    leadingIcon: const AppIcon(Icons.send_outlined, size: 18),
                    child: const Text('推送到局域网设备'),
                  ),
                  const Divider(height: 8),
                  for (final (value, label) in _exports)
                    MenuItemButton(
                      onPressed: () => onExport(value),
                      child: Text(label),
                    ),
                  const Divider(height: 8),
                  MenuItemButton(
                    onPressed: onDelete,
                    leadingIcon: AppIcon(
                      Icons.delete_outline,
                      size: 18,
                      color: Tokens.red,
                    ),
                    child: Text('删除项目', style: TextStyle(color: Tokens.red)),
                  ),
                ],
                builder: (context, controller, _) => OutlinedButton.icon(
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  icon: const AppIcon(Icons.more_horiz, size: 18),
                  label: const Text('更多'),
                ),
              ),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const AppIcon(Icons.add, size: 18),
                label: const Text('添加物料'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProjectQuotes extends StatelessWidget {
  const _ProjectQuotes({required this.state, required this.projectId});
  final AppState state;
  final String projectId;

  @override
  Widget build(BuildContext context) {
    final store = state.store;
    final quotes = store.listQuotations(projectId: projectId, limit: 500);
    if (quotes.isEmpty) {
      return const EmptyState(
        title: '这个项目还没有报价',
        body: '在"报价查询"中导入报价模板，或录入报价时选择这个项目。',
      );
    }
    return ListView.separated(
      itemCount: quotes.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (context, i) {
        final q = quotes[i].data;
        final product = store.get('product', q['product_id']! as String)?.data;
        final supplier = store
            .get('supplier', q['supplier_id']! as String)
            ?.data;
        return ListTile(
          dense: true,
          onTap: () => showQuoteForm(context, state, id: quotes[i].id),
          title: Text('${product?['name'] ?? ''}  ${product?['model'] ?? ''}'),
          subtitle: Text(
            '${supplier?['name'] ?? ''} · 报价日期 ${q['quoted_on'] ?? '未填'}',
          ),
          trailing: Text(
            '${money(q['price'] as String?)} / ${q['unit_snapshot']}',
            style: const TextStyle(fontFeatures: tabular),
          ),
        );
      },
    );
  }
}

class _Changes extends StatelessWidget {
  const _Changes({required this.store, required this.projectId});
  final Store store;
  final String projectId;

  @override
  Widget build(BuildContext context) {
    final changes = store.changes(projectId).reversed.toList();
    return ListView.separated(
      itemCount: changes.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (context, i) {
        final c = changes[i];
        final field = c['field']! as String;
        final what = switch (field) {
          '(created)' => '创建项目',
          '(deleted)' => '删除项目',
          _ => '$field：${c['old']} → ${c['new']}',
        };
        return ListTile(
          dense: true,
          title: Text(what),
          subtitle: Text(
            '${c['device']} · ${DateTime.parse(c['at']! as String).toLocal().toString().substring(0, 16)}',
          ),
        );
      },
    );
  }
}
