import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../app/motion.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';
import '../spec/param_view.dart';
import '../catalog/catalog_page.dart';
import '../quotes/quotes_page.dart';
import '../projects/projects_page.dart';
import '../exchange/exchange_page.dart';
import 'param_migration.dart';
import 'relation_graph.dart';
import 'ontology_graph_host.dart';

/// The data model, data quality and what AI agents get, in one place.
class DataCenterPage extends StatefulWidget {
  const DataCenterPage({
    super.key,
    required this.state,
    this.ontologyViewBuilder,
  });
  final AppState state;
  final OntologyViewBuilder? ontologyViewBuilder;

  @override
  State<DataCenterPage> createState() => _DataCenterPageState();
}

class _DataCenterPageState extends State<DataCenterPage> {
  var selected = 'quotation';
  late Map<String, int> counts;

  @override
  void initState() {
    super.initState();
    counts = widget.state.store.recordCounts();
    widget.state.addListener(_refreshCounts);
  }

  void _refreshCounts() {
    setState(() => counts = widget.state.store.recordCounts());
  }

  @override
  void didUpdateWidget(DataCenterPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_refreshCounts);
      widget.state.addListener(_refreshCounts);
      counts = widget.state.store.recordCounts();
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_refreshCounts);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = RelationGraphPalette.of(context);
    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(
        colorScheme: base.colorScheme.copyWith(
          primary: p.accent,
          onPrimary: p.surface,
          surface: p.surface,
          onSurface: p.ink,
          onSurfaceVariant: p.muted,
          outline: p.border,
          outlineVariant: p.border,
          secondaryContainer: p.tint,
          onSecondaryContainer: p.ink,
        ),
        textTheme: base.textTheme.apply(bodyColor: p.ink, displayColor: p.ink),
        scaffoldBackgroundColor: p.canvas,
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          fillColor: p.surface,
        ),
      ),
      child: Material(
        color: p.canvas,
        child: DefaultTabController(
          length: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
                child: Text(
                  '数据中心',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(24, 4, 24, 0),
                child: Text(
                  '软件里有哪些数据、它们怎样关联、质量如何，以及 AI 能读到什么。',
                  style: TextStyle(color: p.muted),
                ),
              ),
              const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                padding: EdgeInsets.symmetric(horizontal: 12),
                tabs: [
                  Tab(text: '数据模型'),
                  Tab(text: '数据质量'),
                  Tab(text: 'AI 接入'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  // Horizontal gestures belong to the graph and data tables.
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    OntologyGraphHost(
                      counts: counts,
                      selected: selected,
                      onSelect: (t) => setState(() => selected = t),
                      viewBuilder: widget.ontologyViewBuilder,
                      fallback: _ModelTab(
                        counts: counts,
                        selected: selected,
                        onSelect: (t) => setState(() => selected = t),
                      ),
                    ),
                    _QualityTab(state: widget.state),
                    _AiTab(state: widget.state),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _card(
  BuildContext context, {
  required Widget child,
  EdgeInsets? padding,
}) => Container(
  padding: padding ?? const EdgeInsets.all(16),
  decoration: BoxDecoration(
    color: RelationGraphPalette.of(context).surface,
    border: Border.all(color: RelationGraphPalette.of(context).border),
    borderRadius: BorderRadius.circular(Tokens.radius),
  ),
  child: child,
);

const _pagePadding = EdgeInsets.fromLTRB(24, 16, 24, 24);

class _ModelTab extends StatelessWidget {
  const _ModelTab({
    required this.counts,
    required this.selected,
    required this.onSelect,
  });
  final Map<String, int> counts;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = RelationGraphPalette.of(context);
    final base = Theme.of(context);
    return Theme(
      data: base.copyWith(
        colorScheme: base.colorScheme.copyWith(
          primary: p.accent,
          onPrimary: p.surface,
          secondaryContainer: p.tint,
          onSecondaryContainer: p.ink,
          surface: p.surface,
          onSurface: p.ink,
          onSurfaceVariant: p.muted,
          outline: p.border,
          outlineVariant: p.border,
        ),
        textTheme: base.textTheme.apply(bodyColor: p.ink, displayColor: p.ink),
        chipTheme: base.chipTheme.copyWith(
          backgroundColor: p.surface,
          selectedColor: p.tint,
          labelStyle: base.textTheme.labelLarge?.copyWith(color: p.ink),
          secondaryLabelStyle: base.textTheme.labelLarge?.copyWith(
            color: p.ink,
          ),
          checkmarkColor: p.accent,
          side: BorderSide(color: p.border),
        ),
        inputDecorationTheme: base.inputDecorationTheme.copyWith(
          fillColor: p.surface,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final largeText = MediaQuery.textScalerOf(context).scale(14) > 18;
          final sideBySide =
              constraints.maxWidth >= 1060 &&
              constraints.maxHeight >= 560 &&
              !largeText;
          final details = _ObjectDetails(
            type: ontology[selected]!,
            count: counts[selected] ?? 0,
            onSelect: onSelect,
          );
          if (sideBySide) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, size) => RelationGraph(
                        counts: counts,
                        selected: selected,
                        onSelect: onSelect,
                        height: size.maxHeight,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(
                    key: const ValueKey('ontology-inspector'),
                    width: 360,
                    child: SingleChildScrollView(child: details),
                  ),
                ],
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (constraints.maxWidth >= 680)
                RelationGraph(
                  counts: counts,
                  selected: selected,
                  onSelect: onSelect,
                  height: largeText ? 680 : 560,
                )
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final t in ontology.values)
                      ChoiceChip(
                        label: Text('${t.label} ${counts[t.name] ?? 0}'),
                        selected: t.name == selected,
                        onSelected: (_) => onSelect(t.name),
                      ),
                  ],
                ),
              const SizedBox(height: 16),
              details,
            ],
          );
        },
      ),
    );
  }
}

/// The inspector reads the same schema as the graph, including self references.
/// Compact field rows follow the inspector width rather than the window width.
class _ObjectDetails extends StatelessWidget {
  const _ObjectDetails({
    required this.type,
    required this.count,
    required this.onSelect,
  });
  final ObjectType type;
  final int count;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = RelationGraphPalette.of(context);
    return Container(
      key: ValueKey('ontology-details-${type.name}'),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: p.surface,
        border: Border.all(color: p.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: LayoutBuilder(
        builder: (context, size) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('对象详情', style: TextStyle(fontSize: 12, color: p.muted)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  type.label,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  '$count 条记录',
                  style: TextStyle(fontSize: 12, color: p.muted),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(type.name, style: TextStyle(fontSize: 12, color: p.muted)),
            const SizedBox(height: 12),
            Text(
              type.description,
              style: TextStyle(color: p.muted, height: 1.6),
            ),
            const SizedBox(height: 20),
            _Links(type: type.name, onSelect: onSelect),
            const SizedBox(height: 20),
            Text(
              '字段 · ${type.fields.length}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            _Fields(
              type: type,
              onSelect: onSelect,
              compact: size.maxWidth < 640,
            ),
          ],
        ),
      ),
    );
  }
}

class _Links extends StatelessWidget {
  const _Links({required this.type, required this.onSelect});
  final String type;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final p = RelationGraphPalette.of(context);
    Widget row(String title, List<(String, String)> items) => items.isEmpty
        ? const SizedBox()
        : Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 64,
                  child: Text(
                    title,
                    style: TextStyle(fontSize: 12, color: p.muted),
                  ),
                ),
                for (final (target, text) in items)
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(text, style: const TextStyle(fontSize: 12)),
                    onPressed: () => onSelect(target),
                  ),
              ],
            ),
          );
    String field(LinkType l) => ontology[l.from]!.field(l.field)!.label;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('同类引用', [
          for (final l in links)
            if (l.from == type && l.to == type)
              (type, '${field(l)} → ${ontology[type]!.label}'),
        ]),
        row('引用了', [
          for (final l in links)
            if (l.from == type && l.to != type)
              (
                l.to,
                field(l) == ontology[l.to]!.label
                    ? field(l)
                    : '${field(l)} → ${ontology[l.to]!.label}',
              ),
        ]),
        row('被引用于', [
          for (final l in links)
            if (l.to == type && l.from != type)
              (l.from, '${ontology[l.from]!.label}.${field(l)}'),
        ]),
      ],
    );
  }
}

class _Fields extends StatelessWidget {
  const _Fields({
    required this.type,
    required this.onSelect,
    this.compact = false,
  });
  final ObjectType type;
  final ValueChanged<String> onSelect;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final p = RelationGraphPalette.of(context);
    final head = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: p.muted,
    );
    Widget cell(Widget child) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
      child: child,
    );
    Widget kind(FieldSpec f) => f.target == null
        ? Text(f.kind.label, style: const TextStyle(fontSize: 13))
        : InkWell(
            onTap: () => onSelect(f.target!),
            child: Text(
              '${f.kind.label} → ${ontology[f.target]!.label}',
              style: TextStyle(fontSize: 13, color: p.accent),
            ),
          );
    Widget about(FieldSpec f) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (f.description.isNotEmpty)
          Text(
            f.description,
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
        if (f.values != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final e in f.values!.entries) _ValueTag(e.key, e.value),
              ],
            ),
          ),
      ],
    );
    // Phones: one stacked block per field instead of four columns.
    if (compact || MediaQuery.sizeOf(context).width < 600) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final f in type.fields)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: p.border)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        f.label,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        f.name,
                        style: TextStyle(fontSize: 12, color: p.muted),
                      ),
                      kind(f),
                      if (f.required)
                        Text(
                          '必填',
                          style: TextStyle(fontSize: 12, color: p.muted),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  about(f),
                ],
              ),
            ),
        ],
      );
    }
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(2.2),
        1: FlexColumnWidth(1.6),
        2: FixedColumnWidth(44),
        3: FlexColumnWidth(5),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        TableRow(
          decoration: BoxDecoration(color: p.canvas),
          children: [
            for (final h in ['字段', '类型', '必填', '说明'])
              cell(Text(h, style: head)),
          ],
        ),
        for (final f in type.fields)
          TableRow(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: p.border)),
            ),
            children: [
              cell(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(f.label),
                    Text(
                      f.name,
                      style: TextStyle(fontSize: 12, color: p.muted),
                    ),
                  ],
                ),
              ),
              cell(kind(f)),
              cell(
                f.required
                    ? AppIcon(Icons.check, size: 16, color: p.muted)
                    : const SizedBox(),
              ),
              cell(about(f)),
            ],
          ),
      ],
    );
  }
}

/// An enum value and its meaning.
class _ValueTag extends StatelessWidget {
  const _ValueTag(this.value, this.meaning);
  final String value, meaning;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: RelationGraphPalette.of(context).canvas,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$value ',
            style: TextStyle(
              fontFeatures: tabular,
              color: RelationGraphPalette.of(context).ink,
            ),
          ),
          TextSpan(text: meaning),
        ],
      ),
      style: TextStyle(
        fontSize: 12,
        color: RelationGraphPalette.of(context).muted,
      ),
    ),
  );
}

class _QualityTab extends StatefulWidget {
  const _QualityTab({required this.state});
  final AppState state;

  @override
  State<_QualityTab> createState() => _QualityTabState();
}

class _QualityTabState extends State<_QualityTab> {
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
  void didUpdateWidget(covariant _QualityTab oldWidget) {
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

  String _unit(String key) => switch (key) {
    'duplicate_suppliers' || 'duplicate_products' => '组',
    'open_conflicts' => '项冲突',
    'unknown_tax_mode' || 'undated_quotes' => '条报价',
    'needs_inquiry' => '行预算',
    'suppliers_without_contact' => '家供应商',
    _ => '项物料',
  };

  void _openList(BuildContext context, String key) {
    final Widget page = switch (key) {
      'open_conflicts' => ExchangePage(state: state),
      'duplicate_suppliers' || 'suppliers_without_contact' => CatalogPage(
        state: state,
        type: 'supplier',
      ),
      'unknown_tax_mode' || 'undated_quotes' => QuotesPage(state: state),
      'needs_inquiry' => ProjectsPage(state: state),
      _ => CatalogPage(state: state, type: 'product'),
    };
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('完整列表 · 请按问题提示检查')),
          body: page,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final open = checks.where((c) => c.count > 0).length;
    return ListView(
      padding: _pagePadding,
      children: [
        Text(
          open == 0 ? '没有发现需要处理的问题。' : '$open 项需要处理，处理后比价和预算会更可靠。',
          style: TextStyle(color: RelationGraphPalette.of(context).muted),
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
        const SizedBox(height: 12),
        _card(
          context,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final (i, c)
                  in checks.where((c) => showAll || c.count > 0).indexed)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    border: i == 0
                        ? null
                        : Border(
                            top: BorderSide(
                              color: RelationGraphPalette.of(context).border,
                            ),
                          ),
                  ),
                  child: Row(
                    children: [
                      AppIcon(
                        c.count == 0
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 20,
                        color: c.count == 0
                            ? RelationGraphPalette.of(context).muted
                            : Tokens.amber,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.label),
                            Text(
                              '${c.count} ${_unit(c.key)}',
                              style: TextStyle(
                                color: c.count == 0
                                    ? RelationGraphPalette.of(context).muted
                                    : Tokens.amber,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              c.hint,
                              style: TextStyle(
                                fontSize: 12,
                                color: RelationGraphPalette.of(context).muted,
                              ),
                            ),
                            if (c.count > 0 && c.key == 'products_unclassified')
                              TextButton(
                                onPressed: () => showParamFill(context, state),
                                child: const Text('预览补全'),
                              ),
                            if (c.count > 0 &&
                                !{
                                  'products_unclassified',
                                  'products_missing_key_params',
                                  'products_unconfirmed_params',
                                }.contains(c.key))
                              TextButton(
                                onPressed: () => _openList(context, c.key),
                                child: const Text('打开完整列表'),
                              ),
                            if (c.count > 0 &&
                                (c.key == 'products_missing_key_params' ||
                                    c.key == 'products_unconfirmed_params'))
                              TextButton(
                                onPressed: () => showParamView(context, state),
                                child: const Text('打开参数视图（全部物料）'),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        for (final (title, body, button, action) in [
          (
            '参数视图',
            '按类别看物料的关键参数：筛选、逐格修改，逐行或整列确认未确认的值。',
            '打开',
            () => showParamView(context, state),
          ),
          (
            '从型号和规格文字补全参数',
            '电缆按型号解码（如 ZR-KVVP-4×1.5），其他物料从规格和备注里读出参数；'
                '没有参数模板的按名称识别。已有的值不覆盖，先预览，确认后写入（未确认）。',
            '预览补全',
            () => showParamFill(context, state),
          ),
          (
            '关键属性转结构化参数',
            '把物料里自由填写的关键属性（如"温度范围：-40~85℃"）转成有类型、有单位的参数，'
                '并按名称识别参数模板，之后才能按技术要求自动比对。先预览，确认后写入。',
            '预览转换',
            () => showParamMigration(context, state),
          ),
        ]) ...[
          const SizedBox(height: 16),
          _card(
            context,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title),
                    Text(
                      body,
                      style: TextStyle(
                        fontSize: 12,
                        color: RelationGraphPalette.of(context).muted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: action, child: Text(button)),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// The bundled read-only MCP server: next to the exe on Windows, inside
/// the app bundle on macOS; null elsewhere.
String? _mcpCommand() {
  final exe = File(Platform.resolvedExecutable).parent;
  if (Platform.isWindows) return '${exe.path}\\siq-mcp\\bin\\siq_mcp.exe';
  if (Platform.isMacOS) {
    return '${exe.parent.path}/Resources/siq-mcp/bin/siq_mcp';
  }
  return null;
}

class _AiTab extends StatefulWidget {
  const _AiTab({required this.state});
  final AppState state;

  @override
  State<_AiTab> createState() => _AiTabState();
}

class _AiTabState extends State<_AiTab> {
  String query = '';
  bool mcpExpanded = false, rulesExpanded = false;
  AppState get state => widget.state;
  @override
  Widget build(BuildContext context) {
    final guide = agentGuide();
    final filteredTools = agentTools.where((t) {
      final function = t['function']! as Map;
      return '${function['name']} ${function['description']}'
          .toLowerCase()
          .contains(query.trim().toLowerCase());
    }).toList();
    return ListView(
      padding: _pagePadding,
      children: [
        _card(
          context,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '"问数据"里的 AI 助手读取的就是这里的数据模型和规则，并且只能用下列只读工具查询，不能修改数据。'
                '也可以把完整的数据说明复制给其他 AI 工具，让它理解这些数据。',
                style: TextStyle(
                  color: RelationGraphPalette.of(context).muted,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: guide));
                      if (context.mounted) toast(context, '已复制数据说明');
                    },
                    icon: const AppIcon(Icons.copy, size: 18),
                    label: const Text('复制数据说明'),
                  ),
                  Text(
                    '约 ${guide.length} 字，只含结构和规则，不含任何业务数据',
                    style: TextStyle(
                      fontSize: 12,
                      color: RelationGraphPalette.of(context).muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_mcpCommand() case final command?) ...[
          const SizedBox(height: 16),
          ExpansionTile(
            title: const Text('接入其他 AI 工具（MCP）'),
            onExpansionChanged: (value) => setState(() => mcpExpanded = value),
            trailing: AnimatedRotation(
              turns: mcpExpanded ? .25 : 0,
              duration: AppMotion.duration(context),
              child: const AppIcon(Icons.chevron_right),
            ),
            children: [
              _McpCard(
                command: command,
                database:
                    '${state.dataDir.path}${Platform.pathSeparator}supplier.db',
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        Text(
          '只读工具 · ${filteredTools.length}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('ai-tool-search'),
          decoration: const InputDecoration(labelText: '搜索工具名称或用途'),
          onChanged: (value) => setState(() => query = value),
        ),
        if (filteredTools.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text('没有匹配的只读工具'),
          ),
        const SizedBox(height: 8),
        _card(
          context,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final (i, t) in filteredTools.indexed)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    border: i == 0
                        ? null
                        : Border(
                            top: BorderSide(
                              color: RelationGraphPalette.of(context).border,
                            ),
                          ),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final name = Text(
                        (t['function']! as Map)['name'] as String,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      );
                      final description = Text(
                        (t['function']! as Map)['description'] as String,
                        style: const TextStyle(fontSize: 13, height: 1.5),
                      );
                      if (constraints.maxWidth < 600 ||
                          MediaQuery.textScalerOf(context).scale(14) > 18) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            name,
                            const SizedBox(height: 6),
                            description,
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 170, child: name),
                          const SizedBox(width: 16),
                          Expanded(child: description),
                        ],
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ExpansionTile(
          title: const Text('AI 需要遵守的规则'),
          onExpansionChanged: (value) => setState(() => rulesExpanded = value),
          trailing: AnimatedRotation(
            turns: rulesExpanded ? .25 : 0,
            duration: AppMotion.duration(context),
            child: const AppIcon(Icons.chevron_right),
          ),
          children: [
            _card(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final r in rules)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '· ${r.text}',
                        style: const TextStyle(fontSize: 13, height: 1.5),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// How to connect Claude Desktop, Cursor and other MCP clients.
class _McpCard extends StatelessWidget {
  const _McpCard({required this.command, required this.database});
  final String command, database;

  @override
  Widget build(BuildContext context) {
    final config = const JsonEncoder.withIndent('  ').convert({
      'mcpServers': {
        'xunjia': {
          'command': command,
          'args': ['--db', database],
        },
      },
    });
    final bundled = File(command).existsSync();
    return _card(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '接入其他 AI 工具（MCP）',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Text(
            'Claude Desktop、Cursor 等支持 MCP 的工具，可以通过随软件附带的 siq-mcp 直接查询本机数据：'
            '把下面的配置加入该工具的 MCP 设置并重启它。siq-mcp 以只读方式打开数据库，'
            '用的是上面同一组只读工具；查询到的数据会发送给该工具所用的 AI 服务。',
            style: TextStyle(
              color: RelationGraphPalette.of(context).muted,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 10),
          if (!bundled)
            const HintText(
              '当前运行目录未检测到 siq-mcp，暂不能提供可用配置。安装包是否包含该组件需以实际文件为准。',
              icon: Icons.info_outline,
            )
          else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: RelationGraphPalette.of(context).canvas,
                borderRadius: BorderRadius.circular(Tokens.radius),
              ),
              child: SelectableText(
                config,
                style: const TextStyle(
                  fontFamily: monoFamily,
                  fontFamilyFallback: monoFallback,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: config));
                if (context.mounted) toast(context, '已复制 MCP 配置');
              },
              icon: const AppIcon(Icons.copy, size: 18),
              label: const Text('复制配置'),
            ),
          ],
          if (bundled && Platform.isMacOS) ...[
            const SizedBox(height: 8),
            Text(
              'macOS 首次运行时可能询问是否允许访问其他 App 的数据，请选择允许。',
              style: TextStyle(
                fontSize: 12,
                color: RelationGraphPalette.of(context).muted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
