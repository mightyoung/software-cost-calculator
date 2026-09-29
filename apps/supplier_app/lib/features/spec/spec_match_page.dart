import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import 'spec_widgets.dart';

Future<void> showSpecMatch(BuildContext context, AppState state) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => SpecMatchPage(state: state)),
    );

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
  final rows = <ConstraintDraft>[];

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
      rows.add(ConstraintDraft(p.code, opsFor(p).first));
    }
  });

  @override
  Widget build(BuildContext context) {
    final constraints = <SpecConstraint>[];
    for (final r in rows) {
      try {
        if (r.constraint() case final c?) constraints.add(c);
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
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ConstraintFields(
                  draft: r,
                  classCode: classCode!,
                  onChanged: () => setState(() {}),
                  onRemove: () => setState(() {
                    rows.remove(r);
                    r.text.dispose();
                  }),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => rows.add(ConstraintDraft(null, null))),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加条件'),
              ),
            ),
          ],
          if (result != null) ...[
            const SizedBox(height: 16),
            MatchSummary(result: result, cs: constraints),
            const SizedBox(height: 10),
            MatchMatrix(state: widget.state, result: result, cs: constraints),
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
}
