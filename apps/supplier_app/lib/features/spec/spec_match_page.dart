import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../widgets/ledger.dart';
import '../records/open_record.dart';

Future<void> showSpecMatch(BuildContext context, AppState state) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SpecMatchPage(state: state)),
    );

/// One condition being edited: parameter, operator, value text, mark.
class _Row {
  _Row(this.property, this.op);
  String? property;
  String? op;
  ClauseMark mark = ClauseMark.none;
  final text = TextEditingController();
}

/// "按要求找物料": conditions on typed parameters of one class, and the
/// materials that meet them, clause by clause.
class SpecMatchPage extends StatefulWidget {
  const SpecMatchPage({super.key, required this.state});
  final AppState state;

  @override
  State<SpecMatchPage> createState() => _SpecMatchPageState();
}

class _SpecMatchPageState extends State<SpecMatchPage> {
  String? classCode;
  final rows = <_Row>[];
  var showFailed = false;

  @override
  void dispose() {
    for (final r in rows) {
      r.text.dispose();
    }
    super.dispose();
  }

  void _setClass(String? code) => setState(() {
    classCode = code;
    for (final r in rows) {
      r.text.dispose();
    }
    rows.clear();
    if (code == null) return;
    // Start with the class's key parameters, values left to fill.
    for (final cp in classParams(code).where((c) => c.key)) {
      final p = specProperty(cp.property)!;
      if (opsFor(p).isEmpty) continue;
      rows.add(_Row(p.code, opsFor(p).first));
    }
  });

  /// The row's constraint, null while empty; throws when unreadable.
  SpecConstraint? _constraint(_Row r) {
    final p = r.property == null ? null : specProperty(r.property!);
    final t = r.text.text.trim();
    if (p == null || r.op == null || t.isEmpty) return null;
    final parsed = parseParamText(p, t);
    if (parsed == null) throw const FormatException('无法识别');
    return SpecConstraint(
      p.code,
      r.op!,
      normalizeParamValue(p, parsed),
      mark: r.mark,
    );
  }

  @override
  Widget build(BuildContext context) {
    final constraints = <SpecConstraint>[];
    for (final r in rows) {
      try {
        if (_constraint(r) case final c?) constraints.add(c);
      } on FormatException {
        // Shown on the row; left out of the match.
      }
    }
    final result = classCode == null || constraints.isEmpty
        ? null
        : widget.state.store.matchSpec(classCode!, constraints);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Tokens.canvas,
        title: const Text('按要求找物料'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          Text(
            '选择设备类别，按技术要求填写条件（写法同平时：≥8 核、2.3GHz、-20~80℃、IP65、Ex d IIB T4 Gb）。'
            '★ 为实质性条款，不满足即排除；都不标时，所有条件都按必须满足处理。',
            style: TextStyle(color: Tokens.ink2),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 320,
            child: DropdownButtonFormField<String?>(
              initialValue: classCode,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '设备类别'),
              items: [
                for (final c in specClasses)
                  DropdownMenuItem(
                    value: c.code,
                    child: Text(c.parent == null ? c.label : '　${c.label}'),
                  ),
              ],
              onChanged: _setClass,
            ),
          ),
          if (classCode != null) ...[
            const SizedBox(height: 16),
            for (final r in rows) _rowEditor(r),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => rows.add(_Row(null, null))),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加条件'),
              ),
            ),
          ],
          if (result != null) ...[
            const SizedBox(height: 16),
            _summary(result, constraints),
            const SizedBox(height: 10),
            _matrix(result, constraints),
          ] else if (classCode != null)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(
                '至少填写一个条件的值，就会列出候选物料。',
                style: TextStyle(color: Tokens.ink3),
              ),
            ),
        ],
      ),
    );
  }

  Widget _rowEditor(_Row r) {
    final props = [
      for (final cp in classParams(classCode!))
        if (specProperty(cp.property) case final p? when opsFor(p).isNotEmpty)
          p,
    ];
    final p = r.property == null ? null : specProperty(r.property!);
    String? helper, problem;
    try {
      final c = _constraint(r);
      if (c != null) helper = '→ ${c.describe()}';
    } on FormatException {
      problem = p == null ? null : '无法识别，例如：${paramHint(p)}';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.start,
        children: [
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
              onChanged: (m) => setState(() => r.mark = m!),
            ),
          ),
          SizedBox(
            width: 200,
            child: DropdownButtonFormField<String>(
              key: ValueKey('p-${r.hashCode}-$classCode'),
              initialValue: r.property,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '参数'),
              items: [
                for (final q in props)
                  DropdownMenuItem(
                    value: q.code,
                    child: Text(q.label, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() {
                r.property = v;
                r.op = opsFor(specProperty(v!)!).first;
              }),
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
              onChanged: (v) => setState(() => r.op = v),
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
              onChanged: (_) => setState(() {}),
            ),
          ),
          IconButton(
            tooltip: '删除条件',
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() {
              rows.remove(r);
              r.text.dispose();
            }),
          ),
        ],
      ),
    );
  }

  Widget _summary(MatchResult r, List<SpecConstraint> cs) {
    final hints = [
      for (final MapEntry(key: i, value: n) in r.relaxGain.entries)
        if (r.size(MatchGroup.full) == 0)
          '放宽「${specProperty(cs[i].property)?.label ?? cs[i].property}」可多 $n 个',
    ];
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
        if (r.candidates.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '这个类别还没有物料。给物料选择这个参数模板并填写参数后，才能参与匹配。',
              style: TextStyle(color: Tokens.ink3),
            ),
          ),
      ],
    );
  }

  Widget _matrix(MatchResult r, List<SpecConstraint> cs) {
    final failed = r.size(MatchGroup.failed);
    final shown = [
      for (final c in r.candidates)
        if (showFailed || c.group != MatchGroup.failed) c,
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
                    for (final c in shown)
                      cell(
                        cellWidth,
                        InkWell(
                          onTap: () => openRecord(
                            context,
                            widget.state,
                            'product',
                            c.id,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${c.data['name']}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (c.data['model'] case final String m)
                                MonoText(m),
                            ],
                          ),
                        ),
                      ),
                  ]),
                  for (final (i, k) in cs.indexed)
                    row([
                      cell(
                        labelWidth,
                        Text(
                          '${k.mark == ClauseMark.star
                              ? '★ '
                              : k.mark == ClauseMark.triangle
                              ? '▲ '
                              : ''}${k.describe()}',
                        ),
                      ),
                      for (final c in shown)
                        cell(cellWidth, _verdictCell(c.results[i])),
                    ]),
                  row(color: Tokens.sunken, [
                    cell(
                      labelWidth,
                      Text('结论 · 最低有效报价', style: TextStyle(color: Tokens.ink2)),
                    ),
                    for (final c in shown)
                      cell(
                        cellWidth,
                        Column(
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
                                color: c.price == null
                                    ? Tokens.ink3
                                    : Tokens.ink,
                                fontFeatures: tabular,
                              ),
                            ),
                          ],
                        ),
                      ),
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

  Widget _verdictCell(ClauseResult x) {
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
