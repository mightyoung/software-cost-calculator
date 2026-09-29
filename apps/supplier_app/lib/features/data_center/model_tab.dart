import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/theme.dart';
import '../../widgets/app_icon.dart';
import 'relation_graph.dart';

/// 数据模型 without a web view: the native relation graph beside the
/// selected object's links and fields. Also the fallback of the G6 host.
class OntologyModelTab extends StatelessWidget {
  const OntologyModelTab({
    super.key,
    required this.counts,
    required this.selected,
    required this.onSelect,
  });
  final Map<String, int> counts;
  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
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
