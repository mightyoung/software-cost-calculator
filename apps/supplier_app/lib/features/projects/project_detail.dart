import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';
import '../ai/list_to_project.dart';
import '../ai/material_import_page.dart';
import 'budget_table.dart';
import 'item_dialogs.dart';
import 'project_form.dart';

enum _Tab { budget, quotes, changes }

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
            child: _Header(project: p, budget: b, compact: widget.compact),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: pad, vertical: 10),
            child: _Toolbar(
              tab: tab,
              compact: widget.compact,
              onTab: (t) => setState(() => tab = t),
              onEdit: () =>
                  showProjectForm(context, state, id: widget.projectId),
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
                _Tab.quotes => _ProjectQuotes(
                  store: state.store,
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
  });
  final Map<String, Object?> project;
  final Budget budget;
  final bool compact;

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
                style: const TextStyle(fontSize: 12, color: Tokens.accentDeep),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          p['name']! as String,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(meta, style: const TextStyle(fontSize: 13, color: Tokens.ink2)),
        const SizedBox(height: 14),
        LedgerStrip(
          columns: compact ? 2 : null,
          cells: [
            LedgerCell('合同金额', contract == null ? '未填' : yuan(contract)),
            LedgerCell(
              '成本合计',
              yuan(budget.cost),
              alert: budget.contractWarning ? '已达合同金额 $contractPct' : null,
            ),
            LedgerCell(
              '对外报价',
              yuan(budget.price),
              note: '加价 ${p['markup_rate']}%',
            ),
            LedgerCell(
              '毛利',
              yuan(budget.margin),
              note: percent(budget.margin, budget.price),
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
    required this.onExport,
    required this.onAdd,
    required this.onFromList,
    required this.onImport,
  });
  final _Tab tab;
  final bool compact;
  final ValueChanged<_Tab> onTab;
  final VoidCallback onEdit, onAdd, onFromList, onImport;
  final ValueChanged<String> onExport;

  static const _exports = [
    ('quote', '导出项目报价单（给客户）'),
    ('budget', '导出成本预算表（内部）'),
    ('inquiry', '导出待询价清单（给供应商）'),
  ];

  @override
  Widget build(BuildContext context) {
    Widget tabButton(_Tab t, String label) => InkWell(
      onTap: () => onTab(t),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        margin: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: t == tab ? Tokens.ink : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: t == tab ? Tokens.ink : Tokens.ink2,
            fontWeight: t == tab ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
    final tabs = [
      tabButton(_Tab.budget, '成本预算'),
      tabButton(_Tab.quotes, '报价记录'),
      tabButton(_Tab.changes, '变更记录'),
    ];
    if (compact) {
      // Phones: actions live in one overflow menu; "添加" sits by the totals.
      return Row(
        children: [
          ...tabs,
          const Spacer(),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) => switch (v) {
              'edit' => onEdit(),
              'list' => onFromList(),
              'import' => onImport(),
              _ => onExport(v),
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('编辑项目')),
              const PopupMenuItem(value: 'import', child: Text('导入报价信息')),
              const PopupMenuItem(value: 'list', child: Text('从清单生成新项目')),
              for (final (value, label) in _exports)
                PopupMenuItem(value: value, child: Text(label)),
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
                icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                label: const Text('导入报价信息'),
              ),
              OutlinedButton.icon(
                onPressed: onFromList,
                icon: const Icon(Icons.playlist_add_check, size: 18),
                label: const Text('从清单生成'),
              ),
              OutlinedButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('编辑项目'),
              ),
              MenuAnchor(
                menuChildren: [
                  for (final (value, label) in _exports)
                    MenuItemButton(
                      onPressed: () => onExport(value),
                      child: Text(label),
                    ),
                ],
                builder: (context, controller, _) => OutlinedButton.icon(
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('导出'),
                ),
              ),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add, size: 18),
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
  const _ProjectQuotes({required this.store, required this.projectId});
  final Store store;
  final String projectId;

  @override
  Widget build(BuildContext context) {
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
