import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';
import '../spec/param_view.dart';
import 'param_migration.dart';
import 'relation_graph.dart';

/// The data model, data quality and what AI agents get, in one place.
class DataCenterPage extends StatefulWidget {
  const DataCenterPage({super.key, required this.state});
  final AppState state;

  @override
  State<DataCenterPage> createState() => _DataCenterPageState();
}

class _DataCenterPageState extends State<DataCenterPage> {
  var selected = 'quotation';

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
          child: Text('数据中心', style: Theme.of(context).textTheme.titleLarge),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(24, 4, 24, 0),
          child: Text(
            '软件里有哪些数据、它们怎样关联、质量如何，以及 AI 能读到什么。',
            style: TextStyle(color: Tokens.ink2),
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
          child: ListenableBuilder(
            listenable: widget.state,
            builder: (context, _) => TabBarView(
              children: [
                _ModelTab(
                  counts: widget.state.store.recordCounts(),
                  selected: selected,
                  onSelect: (t) => setState(() => selected = t),
                ),
                _QualityTab(state: widget.state),
                _AiTab(state: widget.state),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

Widget _card({required Widget child, EdgeInsets? padding}) => Container(
  padding: padding ?? const EdgeInsets.all(16),
  decoration: BoxDecoration(
    color: Tokens.surface,
    border: Border.all(color: Tokens.rule),
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
    final type = ontology[selected]!;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return ListView(
      padding: _pagePadding,
      children: [
        if (wide)
          _card(
            child: RelationGraph(
              counts: counts,
              selected: selected,
              onSelect: onSelect,
            ),
          )
        else
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in ontology.values)
                ChoiceChip(
                  label: Text('${t.label} ${counts[t.name]}'),
                  selected: t.name == selected,
                  onSelected: (_) => onSelect(t.name),
                ),
            ],
          ),
        const SizedBox(height: 16),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    type.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(width: 8),
                  MonoText(type.name),
                  const Spacer(),
                  Text(
                    '${counts[selected]} 条记录',
                    style: TextStyle(color: Tokens.ink3),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(type.description, style: TextStyle(color: Tokens.ink2)),
              const SizedBox(height: 12),
              _Links(type: selected, onSelect: onSelect),
              const SizedBox(height: 12),
              _Fields(type: type, onSelect: onSelect),
            ],
          ),
        ),
      ],
    );
  }
}

class _Links extends StatelessWidget {
  const _Links({required this.type, required this.onSelect});
  final String type;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
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
                    style: TextStyle(fontSize: 12, color: Tokens.ink3),
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
  const _Fields({required this.type, required this.onSelect});
  final ObjectType type;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final head = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: Tokens.ink2,
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
              style: TextStyle(fontSize: 13, color: Tokens.accentDeep),
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
    if (MediaQuery.sizeOf(context).width < 600) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final f in type.fields)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Tokens.rule)),
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
                      MonoText(f.name),
                      kind(f),
                      if (f.required)
                        Text(
                          '必填',
                          style: TextStyle(fontSize: 12, color: Tokens.ink3),
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
          decoration: BoxDecoration(color: Tokens.sunken),
          children: [
            for (final h in ['字段', '类型', '必填', '说明'])
              cell(Text(h, style: head)),
          ],
        ),
        for (final f in type.fields)
          TableRow(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: Tokens.rule)),
            ),
            children: [
              cell(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text(f.label), MonoText(f.name)],
                ),
              ),
              cell(kind(f)),
              cell(
                f.required
                    ? Icon(Icons.check, size: 16, color: Tokens.ink2)
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
      color: Tokens.sunken,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$value ',
            style: TextStyle(
              fontFamily: monoFamily,
              fontFamilyFallback: monoFallback,
              color: Tokens.ink,
            ),
          ),
          TextSpan(text: meaning),
        ],
      ),
      style: TextStyle(fontSize: 12, color: Tokens.ink2),
    ),
  );
}

class _QualityTab extends StatelessWidget {
  const _QualityTab({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final store = state.store;
    final checks = store.dataQuality();
    final open = checks.where((c) => c.count > 0).length;
    return ListView(
      padding: _pagePadding,
      children: [
        Text(
          open == 0 ? '没有发现需要处理的问题。' : '$open 项需要处理，处理后比价和预算会更可靠。',
          style: TextStyle(color: Tokens.ink2),
        ),
        const SizedBox(height: 12),
        _card(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final (i, c) in checks.indexed)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    border: i == 0
                        ? null
                        : Border(top: BorderSide(color: Tokens.rule)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        c.count == 0
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 20,
                        color: c.count == 0 ? Tokens.ink3 : Tokens.amber,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(c.label),
                            Text(
                              c.hint,
                              style: TextStyle(
                                fontSize: 12,
                                color: Tokens.ink3,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${c.count}',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          fontFeatures: tabular,
                          color: c.count == 0 ? Tokens.ink3 : Tokens.amber,
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
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title),
                      Text(
                        body,
                        style: TextStyle(fontSize: 12, color: Tokens.ink3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
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

class _AiTab extends StatelessWidget {
  const _AiTab({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final guide = agentGuide();
    return ListView(
      padding: _pagePadding,
      children: [
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '"问数据"里的 AI 助手读取的就是这里的数据模型和规则，并且只能用下列只读工具查询，不能修改数据。'
                '也可以把完整的数据说明复制给其他 AI 工具，让它理解这些数据。',
                style: TextStyle(color: Tokens.ink2, height: 1.6),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: guide));
                      if (context.mounted) toast(context, '已复制数据说明');
                    },
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('复制数据说明'),
                  ),
                  Text(
                    '约 ${guide.length} 字，只含结构和规则，不含任何业务数据',
                    style: TextStyle(fontSize: 12, color: Tokens.ink3),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_mcpCommand() case final command?) ...[
          const SizedBox(height: 16),
          _McpCard(
            command: command,
            database:
                '${state.dataDir.path}${Platform.pathSeparator}supplier.db',
          ),
        ],
        const SizedBox(height: 16),
        Text('只读工具', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        _card(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (final (i, t) in agentTools.indexed)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    border: i == 0
                        ? null
                        : Border(top: BorderSide(color: Tokens.rule)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 150,
                        child: MonoText(
                          (t['function']! as Map)['name'] as String,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          (t['function']! as Map)['description'] as String,
                          style: const TextStyle(fontSize: 13, height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text('AI 需要遵守的规则', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        _card(
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
            style: TextStyle(color: Tokens.ink2, height: 1.6),
          ),
          const SizedBox(height: 10),
          if (!bundled)
            const HintText(
              '当前运行的是开发版本，没有附带 siq-mcp；正式安装包里有，届时这里会给出可直接复制的配置。',
              icon: Icons.info_outline,
            )
          else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Tokens.sunken,
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
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('复制配置'),
            ),
          ],
          if (bundled && Platform.isMacOS) ...[
            const SizedBox(height: 8),
            Text(
              'macOS 首次运行时可能询问是否允许访问其他 App 的数据，请选择允许。',
              style: TextStyle(fontSize: 12, color: Tokens.ink3),
            ),
          ],
        ],
      ),
    );
  }
}
