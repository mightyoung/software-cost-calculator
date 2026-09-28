import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';
import 'item_dialogs.dart';

const _warningText = {
  'cheaper_available': ('有更低报价', Icons.trending_down, HintTone.warning),
  'quote_not_valid': ('报价已失效', Icons.event_busy_outlined, HintTone.error),
  'below_min_qty': (
    '未达起订量',
    Icons.production_quantity_limits,
    HintTone.warning,
  ),
  'needs_inquiry': ('待询价', Icons.help_outline, HintTone.warning),
};

/// Still to be inquired and no estimate typed in yet: show "—", not 0.
bool _unpriced(BudgetLine l) =>
    l.warnings.contains('needs_inquiry') && l.data['unit_cost'] == '0';

/// Grouped by cost category with subtotal rows; rows open the line editor.
class BudgetTable extends StatelessWidget {
  const BudgetTable({
    super.key,
    required this.state,
    required this.projectId,
    required this.budget,
    required this.compact,
  });
  final AppState state;
  final String projectId;
  final Budget budget;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (budget.lines.isEmpty) {
      return EmptyState(
        title: '这个项目还没有物料',
        body: '从物料库添加，并自动带出最低有效报价；库里没有的可以先作为待询价添加。',
        actions: [
          OutlinedButton(
            onPressed: () => showAddItems(context, state, projectId),
            child: const Text('添加物料'),
          ),
        ],
      );
    }
    final rows = <Widget>[if (!compact) const _HeaderRow()];
    for (final category in categoryLabels.keys) {
      final lines = budget.lines
          .where((l) => l.data['category'] == category)
          .toList();
      if (lines.isEmpty) continue;
      rows.add(
        _GroupRow(
          label: categoryLabels[category]!,
          count: lines.length,
          cost: budget.costByCategory[category]!,
          price: _sum(lines.map((l) => l.price)),
          compact: compact,
        ),
      );
      for (final l in lines) {
        rows.add(
          _LineRow(
            state: state,
            projectId: projectId,
            line: l,
            compact: compact,
          ),
        );
      }
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Tokens.surface,
        border: Border.all(color: Tokens.rule),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Tokens.radius),
        ),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Tokens.radius),
        ),
        child: ListView(children: rows),
      ),
    );
  }
}

String _sum(Iterable<String> values) {
  var total = BigInt.zero;
  for (final v in values) {
    final p = v.split('.');
    total +=
        BigInt.parse(p.first) * BigInt.from(1000000) +
        BigInt.parse((p.length > 1 ? p[1] : '').padRight(6, '0'));
  }
  final f = (total % BigInt.from(1000000))
      .toString()
      .padLeft(6, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '${total ~/ BigInt.from(1000000)}${f.isEmpty ? '' : '.$f'}';
}

// Supplier sits on the item's second line so the name column keeps ~220px
// at 1280px wide.
const _cols = [
  ('数量', 56.0, true),
  ('单位', 40.0, false),
  ('成本单价', 96.0, true),
  ('成本金额', 104.0, true),
  ('对外金额', 104.0, true),
  ('提示', 112.0, false),
];

Widget _cell(double width, Widget child, {bool right = false}) => SizedBox(
  width: width,
  child: Align(
    alignment: right ? Alignment.topRight : Alignment.topLeft,
    child: child,
  ),
);

const _num = TextStyle(fontSize: 13, fontFeatures: tabular);

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) => Container(
    color: Tokens.sunken,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: DefaultTextStyle.merge(
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Tokens.ink2,
      ),
      child: Row(
        children: [
          const Expanded(child: Text('名称 / 型号')),
          for (final (label, width, right) in _cols)
            Padding(
              padding: const EdgeInsets.only(left: 10),
              child: _cell(width, Text(label), right: right),
            ),
        ],
      ),
    ),
  );
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.label,
    required this.count,
    required this.cost,
    required this.price,
    required this.compact,
  });
  final String label, cost, price;
  final int count;
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Tokens.groupRow,
      border: Border(top: BorderSide(color: Tokens.rule)),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Row(
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        Text('  $count 项', style: TextStyle(fontSize: 12, color: Tokens.ink3)),
        const Spacer(),
        Text(
          money(cost, prefix: '¥'),
          style: _num.copyWith(fontWeight: FontWeight.w600),
        ),
        if (!compact) ...[
          const SizedBox(width: 10),
          SizedBox(
            width: 104,
            child: Text(
              money(price, prefix: '¥'),
              textAlign: TextAlign.right,
              style: _num.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 122),
        ],
      ],
    ),
  );
}

class _LineRow extends StatelessWidget {
  /// Saves one inline edit. A cost that no longer equals the linked quote's
  /// price becomes a manual estimate, so the quote link is dropped.
  String? _saveCell(BuildContext context, String field, String value) {
    final d = line.data;
    final payload = {...d, field: value.replaceAll(',', '')};
    if (field == 'unit_cost' && d['quotation_id'] != null) {
      final quote = state.store.get('quotation', d['quotation_id']! as String);
      if (quote?.data['price'] != payload['unit_cost']) {
        payload['quotation_id'] = null;
      }
    }
    return state.write((s) => s.save('project_item', payload, id: line.id));
  }

  const _LineRow({
    required this.state,
    required this.projectId,
    required this.line,
    required this.compact,
  });
  final AppState state;
  final String projectId;
  final BudgetLine line;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final d = line.data;
    final store = state.store;
    final product = d['product_id'] == null
        ? null
        : store.get('product', d['product_id']! as String)?.data;
    final quote = d['quotation_id'] == null
        ? null
        : store.get('quotation', d['quotation_id']! as String)?.data;
    final supplier = quote == null
        ? null
        : store.get('supplier', quote['supplier_id']! as String)?.data['name']
              as String?;
    final name = (product?['name'] ?? d['name'] ?? '') as String;
    final detail = [
      product?['model'],
      product?['specification'],
      if (!compact) supplier,
    ].whereType<String>().join(' · ');
    final unpriced = _unpriced(line);
    final hints = [
      for (final w in line.warnings)
        if (_warningText[w] case (final text, final icon, final tone)?)
          HintTag(text, icon: icon, tone: tone),
    ];
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
        ),
        if (detail.isNotEmpty) MonoText(detail),
        if (product == null && d['notes'] != null)
          Text(
            d['notes']! as String,
            style: TextStyle(fontSize: 12, color: Tokens.ink3),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
    final body = compact
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    title,
                    if (hints.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(spacing: 4, children: hints),
                    ],
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    unpriced ? '—' : money(line.cost, prefix: '¥'),
                    style: _num.copyWith(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    '${qty(d['qty']! as String)} ${d['unit']}${unpriced ? '' : ' × ${money(d['unit_cost']! as String)}'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Tokens.ink3,
                      fontFeatures: tabular,
                    ),
                  ),
                ],
              ),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: title),
              for (final (i, child) in [
                _InlineCell(
                  key: ValueKey('${line.id}-qty'),
                  value: d['qty']! as String,
                  display: qty(d['qty']! as String),
                  onSave: (v) => _saveCell(context, 'qty', v),
                ),
                Text(
                  d['unit']! as String,
                  style: const TextStyle(fontSize: 13),
                ),
                _InlineCell(
                  key: ValueKey('${line.id}-cost'),
                  value: d['unit_cost']! as String,
                  display: unpriced ? '—' : money(d['unit_cost']! as String),
                  onSave: (v) => _saveCell(context, 'unit_cost', v),
                ),
                Text(unpriced ? '—' : money(line.cost), style: _num),
                Text(unpriced ? '—' : money(line.price), style: _num),
                Wrap(spacing: 4, runSpacing: 4, children: hints),
              ].indexed)
                Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: _cell(_cols[i].$2, child, right: _cols[i].$3),
                ),
            ],
          );
    return InkWell(
      onTap: () => showItemEditor(context, state, projectId, itemId: line.id),
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: Tokens.rule)),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: compact ? 12 : 8,
        ),
        child: body,
      ),
    );
  }
}

class BudgetTotals extends StatelessWidget {
  const BudgetTotals({
    super.key,
    required this.budget,
    required this.compact,
    required this.margin,
    this.onAdd,
  });
  final Budget budget;
  final bool compact;
  final double margin;

  /// Phones put the add action next to the totals, within thumb reach.
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final pending = budget.lines.where(_unpriced).length;
    Widget figure(String label, String value) => Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 13, color: Tokens.ink2),
        children: [
          TextSpan(text: '$label  '),
          TextSpan(
            text: money(value, prefix: '¥'),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Tokens.ink,
              fontFeatures: tabular,
            ),
          ),
        ],
      ),
    );
    // On desktops the totals stay in view in the ledger strip above; the
    // footer only speaks up when lines are left out of them.
    if (!compact && pending == 0) return const SizedBox(height: 16);
    return Container(
      margin: EdgeInsets.fromLTRB(margin, 0, margin, compact ? 8 : 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Tokens.surface,
        border: Border(
          top: BorderSide(color: Tokens.ink, width: 2),
          left: BorderSide(color: Tokens.rule),
          right: BorderSide(color: Tokens.rule),
          bottom: BorderSide(color: Tokens.rule),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              alignment: onAdd == null
                  ? WrapAlignment.end
                  : WrapAlignment.start,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 28,
              runSpacing: 6,
              children: [
                if (pending > 0)
                  HintText('含 $pending 项待询价，未计入', icon: Icons.help_outline),
                if (compact) ...[
                  figure('成本合计', budget.cost),
                  figure('毛利', budget.margin),
                ],
              ],
            ),
          ),
          if (onAdd != null) ...[
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加'),
            ),
          ],
        ],
      ),
    );
  }
}

/// A table cell that edits in place: click to edit, Enter or leaving saves,
/// Esc cancels. Unsaved text is underlined with dashes (not yet confirmed).
class _InlineCell extends StatefulWidget {
  const _InlineCell({
    super.key,
    required this.value,
    required this.display,
    required this.onSave,
  });
  final String value, display;

  /// Returns an error message, or null when saved.
  final String? Function(String value) onSave;

  @override
  State<_InlineCell> createState() => _InlineCellState();
}

class _InlineCellState extends State<_InlineCell> {
  late final controller = TextEditingController(text: widget.value);
  final focus = FocusNode();

  /// The cell while not editing: arrows and Tab move between cells, Enter
  /// or a digit starts editing (as in Excel).
  final cellFocus = FocusNode();
  var editing = false;
  String? error;

  @override
  void initState() {
    super.initState();
    focus.addListener(() {
      if (!focus.hasFocus && editing) _commit();
    });
  }

  @override
  void dispose() {
    controller.dispose();
    focus.dispose();
    cellFocus.dispose();
    super.dispose();
  }

  void _commit({TraversalDirection? then}) {
    final text = controller.text.trim();
    String? err;
    if (text == widget.value || text.isEmpty) {
      _cancel();
    } else {
      err = widget.onSave(text);
      if (!mounted) return;
      setState(() {
        error = err;
        editing = err != null;
      });
    }
    if (err == null && then != null) {
      // Back on the cell, then on to the neighbour once the row redrew.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        cellFocus.requestFocus();
        cellFocus.focusInDirection(then);
      });
    }
  }

  void _edit([String? typed]) {
    controller.text = typed ?? widget.value;
    controller.selection = typed == null
        ? TextSelection(baseOffset: 0, extentOffset: controller.text.length)
        : TextSelection.collapsed(offset: controller.text.length);
    setState(() => editing = true);
    focus.requestFocus();
  }

  void _cancel() => setState(() {
    controller.text = widget.value;
    editing = false;
    error = null;
  });

  @override
  Widget build(BuildContext context) {
    if (!editing) {
      return Focus(
        onKeyEvent: (_, event) {
          final ch = event.character;
          if (event is! KeyUpEvent &&
              ch != null &&
              RegExp(r'^[0-9.]$').hasMatch(ch)) {
            _edit(ch);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: InkWell(
          focusNode: cellFocus,
          onTap: _edit,
          child: Text(widget.display, style: _num),
        ),
      );
    }
    final dirty = controller.text.trim() != widget.value;
    return Tooltip(
      message: error ?? '',
      child: CustomPaint(
        foregroundPainter: dirty
            ? _DashedUnderline(error != null ? Tokens.red : Tokens.accent)
            : null,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () {
              _cancel();
              cellFocus.requestFocus();
            },
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                _commit(then: TraversalDirection.down),
            const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                _commit(then: TraversalDirection.up),
          },
          child: TextField(
            controller: controller,
            focusNode: focus,
            textAlign: TextAlign.right,
            style: _num,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _commit(then: TraversalDirection.down),
            decoration: InputDecoration(
              isDense: true,
              filled: false,
              contentPadding: const EdgeInsets.symmetric(vertical: 2),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: dirty
                  ? InputBorder.none
                  : UnderlineInputBorder(
                      borderSide: BorderSide(
                        color: error != null ? Tokens.red : Tokens.accent,
                        width: 2,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedUnderline extends CustomPainter {
  _DashedUnderline(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    for (var x = 0.0; x < size.width; x += 6) {
      canvas.drawLine(
        Offset(x, size.height - 1),
        Offset((x + 3).clamp(0, size.width), size.height - 1),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedUnderline old) => old.color != color;
}
