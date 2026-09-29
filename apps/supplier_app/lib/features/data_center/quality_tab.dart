import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../widgets/app_icon.dart';
import '../catalog/catalog_page.dart';
import '../exchange/exchange_page.dart';
import '../projects/projects_page.dart';
import '../quotes/quotes_page.dart';
import '../spec/param_view.dart';
import '../spec/spec_request_list.dart';
import 'data_center_page.dart';
import 'param_migration.dart';
import 'relation_graph.dart';

/// 数据质量, grouped by the part of the work a finding belongs to. What a
/// project asks for (技术要求) and what a material offers (物料参数) are
/// separate groups; the parameter tools sit with the parameter checks.
class QualityTab extends StatefulWidget {
  const QualityTab({super.key, required this.state});
  final AppState state;

  @override
  State<QualityTab> createState() => _QualityTabState();
}

class _QualityTabState extends State<QualityTab> {
  bool showAll = false;
  late List<QualityCheck> checks;
  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _refresh();
    state.addListener(_refresh);
  }

  void _refresh() {
    checks = state.store.dataQuality();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant QualityTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != state) {
      oldWidget.state.removeListener(_refresh);
      state.addListener(_refresh);
      _refresh();
    }
  }

  @override
  void dispose() {
    state.removeListener(_refresh);
    super.dispose();
  }

  static String _unit(String key) => switch (key) {
    'duplicate_suppliers' || 'duplicate_products' => '组',
    'open_conflicts' => '项冲突',
    'unknown_tax_mode' || 'undated_quotes' => '条报价',
    'needs_inquiry' => '行预算',
    'spec_clauses_unreviewed' => '条条款',
    'spec_items_unchosen' => '项需求',
    'suppliers_without_contact' => '家供应商',
    _ => '项物料',
  };

  void _push(BuildContext context, Widget page) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('完整列表 · 请按问题提示检查')),
        body: page,
      ),
    ),
  );

  /// Where a finding is fixed, as (button label, action).
  (String, VoidCallback) _action(BuildContext context, String key) =>
      switch (key) {
        'spec_clauses_unreviewed' || 'spec_items_unchosen' => (
          '打开技术要求',
          () => showSpecRequests(context, state),
        ),
        'products_unclassified' => (
          '预览补全',
          () => showParamFill(context, state),
        ),
        'products_missing_key_params' || 'products_unconfirmed_params' => (
          '打开物料参数表',
          () => showParamView(context, state),
        ),
        'open_conflicts' => (
          '打开完整列表',
          () => _push(context, ExchangePage(state: state)),
        ),
        'duplicate_suppliers' || 'suppliers_without_contact' => (
          '打开完整列表',
          () => _push(context, CatalogPage(state: state, type: 'supplier')),
        ),
        'unknown_tax_mode' || 'undated_quotes' => (
          '打开完整列表',
          () => _push(context, QuotesPage(state: state)),
        ),
        'needs_inquiry' => (
          '打开完整列表',
          () => _push(context, ProjectsPage(state: state)),
        ),
        _ => (
          '打开完整列表',
          () => _push(context, CatalogPage(state: state, type: 'product')),
        ),
      };

  @override
  Widget build(BuildContext context) {
    final p = RelationGraphPalette.of(context);
    final open = checks.where((c) => c.count > 0).length;
    return ListView(
      padding: dataCenterPadding,
      children: [
        Text(
          open == 0 ? '没有发现需要处理的问题。' : '$open 项需要处理，处理后比价、选型和预算会更可靠。',
          style: TextStyle(color: p.muted),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: Text('待处理 $open'),
              selected: !showAll,
              onSelected: (_) => setState(() => showAll = false),
            ),
            ChoiceChip(
              label: Text('全部 ${checks.length}'),
              selected: showAll,
              onSelected: (_) => setState(() => showAll = true),
            ),
          ],
        ),
        for (final area in QualityArea.values) ..._area(context, area),
      ],
    );
  }

  List<Widget> _area(BuildContext context, QualityArea area) {
    final p = RelationGraphPalette.of(context);
    final shown = [
      for (final c in checks)
        if (c.area == area && (showAll || c.count > 0)) c,
    ];
    final tools = area == QualityArea.parameters;
    if (shown.isEmpty && !tools) return const [];
    return [
      const SizedBox(height: 24),
      Text(area.label, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      dataCenterCard(
        context,
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, c) in shown.indexed) _row(context, c, top: i > 0),
            if (tools) _parameterTools(context, top: shown.isNotEmpty),
            if (!tools && shown.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('没有问题', style: TextStyle(color: p.muted)),
              ),
          ],
        ),
      ),
    ];
  }

  Widget _row(BuildContext context, QualityCheck c, {required bool top}) {
    final p = RelationGraphPalette.of(context);
    final tone = c.count == 0 ? p.muted : Tokens.amber;
    final (label, action) = _action(context, c.key);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        border: top ? Border(top: BorderSide(color: p.border)) : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(
            c.count == 0 ? Icons.check_circle_outline : Icons.error_outline,
            size: 20,
            color: tone,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c.label),
                Text(
                  '${c.count} ${_unit(c.key)}',
                  style: TextStyle(color: tone, fontWeight: FontWeight.w600),
                ),
                Text(c.hint, style: TextStyle(fontSize: 12, color: p.muted)),
                if (c.count > 0)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(onPressed: action, child: Text(label)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Tools that work on material parameters in bulk; each previews first.
  Widget _parameterTools(BuildContext context, {required bool top}) {
    final p = RelationGraphPalette.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.canvas,
        border: top ? Border(top: BorderSide(color: p.border)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '物料参数是物料自身能提供的值，技术要求按参数字典与它们比对。'
            '以下操作都会先预览，确认后写入（未确认）。',
            style: TextStyle(fontSize: 12, color: p.muted, height: 1.5),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => showParamView(context, state),
                child: const Text('物料参数表'),
              ),
              Tooltip(
                message: '电缆按型号解码，其他物料从规格说明和备注读出参数；已有的值不覆盖',
                child: OutlinedButton(
                  onPressed: () => showParamFill(context, state),
                  child: const Text('从型号和规格说明补全'),
                ),
              ),
              Tooltip(
                message: '把自由填写的关键属性（如"温度范围：-40~85℃"）转成有类型、有单位的物料参数',
                child: OutlinedButton(
                  onPressed: () => showParamMigration(context, state),
                  child: const Text('关键属性转物料参数'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
