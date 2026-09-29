import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';
import '../records/open_record.dart';

/// One condition being edited: parameter, operator, value text, mark.
class ConstraintDraft {
  ConstraintDraft(this.property, this.op, {String text = ''})
    : text = TextEditingController(text: text);

  /// A draft showing an existing constraint.
  factory ConstraintDraft.of(SpecConstraint c) {
    final p = specProperty(c.property);
    return ConstraintDraft(
      c.property,
      c.op,
      text: p == null ? '' : formatParamValue(p, c.value),
    )..mark = c.mark;
  }
  String? property;
  String? op;
  ClauseMark mark = ClauseMark.none;
  final TextEditingController text;

  /// The constraint, null while empty; throws [FormatException] when the
  /// value cannot be read.
  SpecConstraint? constraint({String? evidence}) {
    final p = property == null ? null : specProperty(property!);
    final t = text.text.trim();
    if (p == null || op == null || t.isEmpty) return null;
    final parsed = parseParamText(p, t);
    if (parsed == null) throw const FormatException('无法识别');
    return SpecConstraint(
      p.code,
      op!,
      normalizeParamValue(p, parsed),
      mark: mark,
      text: evidence,
    );
  }
}

/// Mark (optional), parameter, operator and value of one condition, with a
/// live reading of the value under it.
class ConstraintFields extends StatelessWidget {
  const ConstraintFields({
    super.key,
    required this.draft,
    required this.classCode,
    required this.onChanged,
    this.onRemove,
    this.showMark = true,
  });
  final ConstraintDraft draft;
  final String classCode;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;
  final bool showMark;

  @override
  Widget build(BuildContext context) {
    final r = draft;
    final props = [
      for (final cp in classParams(classCode))
        if (specProperty(cp.property) case final p? when opsFor(p).isNotEmpty)
          p,
    ];
    final p = r.property == null ? null : specProperty(r.property!);
    String? helper, problem;
    try {
      final c = r.constraint();
      if (c != null) helper = '→ ${c.describe()}';
    } on FormatException {
      problem = p == null ? null : '无法识别，例如：${paramHint(p)}';
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.start,
      children: [
        if (showMark)
          SizedBox(
            width: 132,
            child: DropdownButtonFormField<ClauseMark>(
              initialValue: r.mark,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '条款'),
              items: [
                for (final m in ClauseMark.values)
                  DropdownMenuItem(value: m, child: Text(markLabels[m]!)),
              ],
              onChanged: (m) {
                r.mark = m!;
                onChanged();
              },
            ),
          ),
        SizedBox(
          width: 200,
          child: DropdownButtonFormField<String>(
            key: ValueKey('p-${r.hashCode}-$classCode'),
            initialValue: props.any((q) => q.code == r.property)
                ? r.property
                : null,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '参数'),
            items: [
              for (final q in props)
                DropdownMenuItem(
                  value: q.code,
                  child: Text(q.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) {
              r.property = v;
              r.op = opsFor(specProperty(v!)!).first;
              onChanged();
            },
          ),
        ),
        SizedBox(
          width: 120,
          child: DropdownButtonFormField<String>(
            key: ValueKey('o-${r.hashCode}-${r.property}'),
            initialValue: r.op,
            decoration: const InputDecoration(labelText: '比较'),
            items: [
              if (p != null)
                for (final o in opsFor(p))
                  DropdownMenuItem(value: o, child: Text(opLabels[o]!)),
            ],
            onChanged: (v) {
              r.op = v;
              onChanged();
            },
          ),
        ),
        SizedBox(
          width: 260,
          child: TextField(
            controller: r.text,
            decoration: InputDecoration(
              labelText: '要求值',
              hintText: p == null ? null : paramHint(p),
              helperText: problem == null ? helper : null,
              errorText: problem,
              helperMaxLines: 2,
              errorMaxLines: 2,
            ),
            onChanged: (_) => onChanged(),
          ),
        ),
        if (onRemove != null)
          IconButton(
            tooltip: '删除条件',
            icon: const Icon(Icons.close, size: 18),
            onPressed: onRemove,
          ),
      ],
    );
  }
}

String markPrefix(ClauseMark m) => switch (m) {
  ClauseMark.star => '★ ',
  ClauseMark.triangle => '▲ ',
  ClauseMark.none => '',
};

/// Group counts, the all-hard note and relaxation hints of a match.
class MatchSummary extends StatelessWidget {
  const MatchSummary({super.key, required this.result, required this.cs});
  final MatchResult result;
  final List<SpecConstraint> cs;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final hints = [
      for (final MapEntry(key: i, value: n) in r.relaxGain.entries)
        if (r.size(MatchGroup.full) == 0)
          '放宽「${specProperty(cs[i].property)?.label ?? cs[i].property}」可多 $n 个',
    ];
    if (r.candidates.isEmpty) {
      return Text(
        '这个类别还没有物料。给物料选择这个参数模板并填写参数后，才能参与匹配。',
        style: TextStyle(color: Tokens.ink3),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          [
            for (final g in MatchGroup.values)
              '${matchGroupLabels[g]} ${r.size(g)}',
          ].join(' · '),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        if (r.allHard)
          Text(
            '条件都未标 ★ / ▲，全部按必须满足处理。',
            style: TextStyle(fontSize: 12, color: Tokens.ink3),
          ),
        if (hints.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: HintText(
              '没有完全满足的物料：${hints.join('；')}',
              icon: Icons.lightbulb_outline,
            ),
          ),
      ],
    );
  }
}

/// Conditions × candidates, clause by clause (design §10.3). With
/// [onChoose], each candidate gets a 定选 button; [chosenId] is marked.
class MatchMatrix extends StatefulWidget {
  const MatchMatrix({
    super.key,
    required this.state,
    required this.result,
    required this.cs,
    this.onChoose,
    this.chosenId,
    this.chosenBefore = const {},
  });
  final AppState state;
  final MatchResult result;
  final List<SpecConstraint> cs;

  /// Times each material was chosen for requirements of this class.
  final Map<String, int> chosenBefore;
  final ValueChanged<Candidate>? onChoose;
  final String? chosenId;

  @override
  State<MatchMatrix> createState() => _MatchMatrixState();
}

class _MatchMatrixState extends State<MatchMatrix> {
  var showFailed = false;

  @override
  Widget build(BuildContext context) {
    final r = widget.result, cs = widget.cs;
    final failed = r.size(MatchGroup.failed);
    final shown = [
      for (final c in r.candidates)
        if (showFailed ||
            c.group != MatchGroup.failed ||
            c.id == widget.chosenId)
          c,
    ].take(12).toList();
    const labelWidth = 240.0, cellWidth = 170.0;
    Widget cell(double w, Widget child, {Color? color}) => Container(
      width: w,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color,
        border: Border(right: BorderSide(color: Tokens.rule)),
      ),
      child: child,
    );
    Widget row(List<Widget> cells, {Color? color}) => Container(
      decoration: BoxDecoration(
        color: color,
        border: Border(bottom: BorderSide(color: Tokens.rule)),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: cells,
        ),
      ),
    );
    if (r.candidates.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (shown.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Container(
              decoration: BoxDecoration(
                color: Tokens.surface,
                border: Border.all(color: Tokens.rule),
                borderRadius: BorderRadius.circular(Tokens.radius),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  row(color: Tokens.sunken, [
                    cell(
                      labelWidth,
                      Text(
                        '条件',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Tokens.ink2,
                        ),
                      ),
                    ),
                    for (final c in shown) cell(cellWidth, _head(c)),
                  ]),
                  for (final (i, k) in cs.indexed)
                    row([
                      cell(
                        labelWidth,
                        Text('${markPrefix(k.mark)}${k.describe()}'),
                      ),
                      for (final c in shown)
                        cell(cellWidth, VerdictCell(x: c.results[i])),
                    ]),
                  row(color: Tokens.sunken, [
                    cell(
                      labelWidth,
                      Text('结论 · 最低有效报价', style: TextStyle(color: Tokens.ink2)),
                    ),
                    for (final c in shown) cell(cellWidth, _foot(c)),
                  ]),
                ],
              ),
            ),
          ),
        if (failed > 0)
          TextButton(
            onPressed: () => setState(() => showFailed = !showFailed),
            child: Text(showFailed ? '隐藏不满足的物料' : '显示不满足的 $failed 个物料'),
          ),
        const SizedBox(height: 6),
        Text(
          '✓ 满足　✗ 不满足　? 待确认　+ 正偏离（优于要求）。点物料名查看详情。',
          style: TextStyle(fontSize: 12, color: Tokens.ink3),
        ),
      ],
    );
  }

  Widget _head(Candidate c) => InkWell(
    onTap: () => openRecord(context, widget.state, 'product', c.id),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${c.data['name']}',
          style: const TextStyle(fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis,
        ),
        if (c.data['model'] case final String m) MonoText(m),
        if (widget.chosenBefore[c.id] case final n?)
          Text('曾定选 $n 次', style: TextStyle(fontSize: 12, color: Tokens.ink3)),
      ],
    ),
  );

  Widget _foot(Candidate c) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      HintTag(
        matchGroupLabels[c.group]!,
        icon: switch (c.group) {
          MatchGroup.full => Icons.check_circle_outline,
          MatchGroup.partial => Icons.help_outline,
          MatchGroup.failed => Icons.block,
        },
        tone: switch (c.group) {
          MatchGroup.full => HintTone.success,
          MatchGroup.partial => HintTone.warning,
          MatchGroup.failed => HintTone.error,
        },
      ),
      const SizedBox(height: 4),
      Text(
        c.price == null
            ? '暂无有效报价'
            : '${money(c.price, prefix: '¥')} / ${c.priceUnit}',
        style: TextStyle(
          fontSize: 12,
          color: c.price == null ? Tokens.ink3 : Tokens.ink,
          fontFeatures: tabular,
        ),
      ),
      if (widget.onChoose != null) ...[
        const SizedBox(height: 6),
        c.id == widget.chosenId
            ? HintTag('已定选', icon: Icons.task_alt, tone: HintTone.success)
            : OutlinedButton(
                onPressed: () => widget.onChoose!(c),
                child: const Text('定选'),
              ),
      ],
    ],
  );
}

/// ✓ / ✗ / ? with the material's value and why.
class VerdictCell extends StatelessWidget {
  const VerdictCell({super.key, required this.x});
  final ClauseResult x;

  @override
  Widget build(BuildContext context) {
    final p = specProperty(x.constraint.property);
    final (mark, color) = switch (x.verdict.outcome) {
      Outcome.exact => ('✓', Tokens.green),
      Outcome.better => ('✓ +', Tokens.green),
      Outcome.worse => ('✗', Tokens.red),
      Outcome.unknown => ('?', Tokens.amber),
    };
    final value = x.have == null || p == null
        ? '缺少参数'
        : formatParamValue(p, x.have!);
    return Tooltip(
      message: [
        ?x.verdict.note,
        if (x.derived) '由单条容量 × 条数推算',
        if (x.unconfirmed) '参数未确认',
      ].join('；'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$mark  $value',
            style: TextStyle(color: color, fontWeight: FontWeight.w500),
          ),
          if (x.verdict.note case final n? when n != value)
            Text(
              n,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Tokens.ink3),
            ),
          if (x.unconfirmed || x.derived)
            Text(
              x.derived ? '推算' : '未确认',
              style: TextStyle(fontSize: 12, color: Tokens.amber),
            ),
        ],
      ),
    );
  }
}
