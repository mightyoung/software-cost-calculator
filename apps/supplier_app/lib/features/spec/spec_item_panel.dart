import 'dart:convert';

import 'package:flutter/material.dart';

import '../../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';
import 'spec_widgets.dart';
import 'supplier_responses.dart';

/// One requirement item: class, clauses to review (② 核对), the match
/// (③ 匹配) and the choice with answers to text clauses (④ 定选).
class SpecItemPanel extends StatelessWidget {
  const SpecItemPanel({
    super.key,
    required this.state,
    required this.itemId,
    this.resumeJobId,
  });
  final AppState state;
  final String itemId;
  final String? resumeJobId;

  /// Saves clauses; a chosen material is judged again so the deviation
  /// table always matches the clauses.
  void _save(BuildContext context, List<SpecClause> clauses, {String? cls}) {
    final problem = state.write((s) {
      s.saveClauses(itemId, clauses, specClass: cls);
      final chosen = s.get('spec_item', itemId)!.data['chosen_product_id'];
      if (chosen != null) s.chooseProduct(itemId, chosen as String);
    });
    if (problem != null) toast(context, problem);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final item = state.store.get('spec_item', itemId);
      if (item == null || item.deleted) {
        return const EmptyState(title: '需求项已删除', body: '');
      }
      final d = item.data;
      final cls = d['spec_class'] as String?;
      final clauses = clausesOf(item);
      final open = clauses.where((c) => !c.reviewed).length;
      final answers = {
        for (final r in snapshotRows(item) ?? const <Map<String, Object?>>[])
          r['n']: r,
      };
      return ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          Text(
            '${d['seq']}. ${d['name']}'
            '${d['qty'] == null ? '' : '　×${d['qty']}${d['unit'] ?? ''}'}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 320,
            child: DropdownButtonFormField<String?>(
              key: ValueKey('cls-$itemId-$cls'),
              initialValue: cls,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '设备类别（参数模板）',
                helperText: '改类别后，未核对的条款会按新类别重新识别',
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('类别待定')),
                for (final c in specClasses)
                  DropdownMenuItem(
                    value: c.code,
                    child: Text(c.parent == null ? c.label : '　${c.label}'),
                  ),
              ],
              onChanged: (v) => _save(context, clauses, cls: v),
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('条款', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 8),
              Text(
                open == 0 ? '全部已核对' : '$open 条待核对',
                style: TextStyle(
                  color: open == 0 ? Tokens.green : Tokens.amber,
                ),
              ),
              if (state.specAi &&
                  cls != null &&
                  clauses.any(
                    (c) => !c.reviewed && (c.isText || c.hint != null),
                  ))
                _AiButton(
                  state: state,
                  classCode: cls,
                  clauses: clauses,
                  itemId: itemId,
                  resumeJobId: resumeJobId,
                ),
              if (open > 0)
                TextButton.icon(
                  onPressed: () => _save(context, [
                    for (final c in clauses) c.copyWith(reviewed: true),
                  ]),
                  icon: const AppIcon(Icons.done_all, size: 18),
                  label: const Text('全部确认'),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (clauses.isEmpty)
            Text('没有条款。', style: TextStyle(color: Tokens.ink3)),
          for (final (i, c) in clauses.indexed)
            _ClauseCard(
              key: ValueKey('clause-$itemId-${c.n}'),
              clause: c,
              classCode: cls,
              answer: d['chosen_product_id'] == null ? null : answers[c.n],
              onChanged: (next) => _save(context, [...clauses]..[i] = next),
              onAnswer: (text, outcome) {
                final problem = state.write(
                  (s) => s.setClauseResponse(itemId, c.n, text, outcome),
                );
                if (problem != null) toast(context, problem);
              },
            ),
          const SizedBox(height: 24),
          Text('匹配与定选', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          _Match(state: state, item: item, clauses: clauses, open: open),
          if (state.store.responsesOf(itemId) case final rs
              when rs.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text('供应商响应', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SupplierResponses(state: state, item: item, responses: rs),
          ],
        ],
      );
    },
  );
}

/// 用 AI 读未识别的条款: the open clauses go to the model; what passes the
/// checks comes back unreviewed, marked as AI's.
class _AiButton extends StatefulWidget {
  const _AiButton({
    required this.state,
    required this.classCode,
    required this.clauses,
    required this.itemId,
    this.resumeJobId,
  });
  final AppState state;
  final String classCode;
  final List<SpecClause> clauses;
  final String itemId;
  final String? resumeJobId;

  @override
  State<_AiButton> createState() => _AiButtonState();
}

class _AiButtonState extends State<_AiButton> {
  var busy = false;
  AiCancellation? _cancellation;
  String? _resumeId;

  @override
  void initState() {
    super.initState();
    _resumeId = widget.resumeJobId;
    if (_resumeId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _run();
      });
    }
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    if (busy) return;
    final cancellation = _cancellation = AiCancellation();
    final classCode = widget.classCode;
    final clauses = widget.clauses;
    final snapshot = jsonEncode([for (final c in clauses) c.toJson()]);
    setState(() => busy = true);
    try {
      String? jobId;
      final resumeId = _resumeId;
      _resumeId = null;
      final r = await widget.state.runAiTask(
        AiTask.clauseReading,
        {
          'itemId': widget.itemId,
          'classCode': classCode,
          'clauses': [for (final c in clauses) c.toJson()],
        },
        (llm) =>
            aiReadClauses(llm, classCode, clauses, cancellation: cancellation),
        resumeId: resumeId,
        cancellation: cancellation,
        onCreated: (id) => jobId = id,
      );
      if (!mounted) return;
      final current = widget.state.store.get('spec_item', widget.itemId);
      if (current == null ||
          current.deleted ||
          current.data['spec_class'] != classCode ||
          jsonEncode([for (final c in clausesOf(current)) c.toJson()]) !=
              snapshot) {
        toast(context, '条款已修改，本次 AI 结果未覆盖你的修改，请重新解析');
        return;
      }
      final problem = widget.state.write(
        (_) => widget.state.commitAiTask(jobId, (s) {
          s.saveClauses(widget.itemId, r.clauses);
          final chosen = s
              .get('spec_item', widget.itemId)!
              .data['chosen_product_id'];
          if (chosen != null) s.chooseProduct(widget.itemId, chosen as String);
        }),
      );
      if (problem != null) {
        toast(context, problem);
        return;
      }
      toast(
        context,
        r.added == 0 && r.dropped == 0
            ? 'AI 没有读出新的条件'
            : 'AI 补充了 ${r.added} 个条件${r.dropped > 0 ? '，${r.dropped} 个与原文对不上已丢弃' : ''}，请逐条核对',
      );
    } on LlmException catch (e) {
      if (mounted) toast(context, 'AI 解析失败：${e.message}');
    } catch (e) {
      if (mounted) toast(context, 'AI 解析未完成：${friendlyError('$e')}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: busy ? () => _cancellation?.cancel() : _run,
    icon: busy
        ? const SizedBox.square(
            dimension: 16,
            child: TaskProgress(compact: true, strokeWidth: 2),
          )
        : const AppIcon(Icons.auto_awesome_outlined, size: 18),
    label: Text(busy ? '停止解析' : '用 AI 读未识别的条款'),
  );
}

class _Match extends StatelessWidget {
  const _Match({
    required this.state,
    required this.item,
    required this.clauses,
    required this.open,
  });
  final AppState state;
  final Record item;
  final List<SpecClause> clauses;
  final int open;

  @override
  Widget build(BuildContext context) {
    final cls = item.data['spec_class'] as String?;
    final cs = constraintsOf(clauses);
    final chosen = item.data['chosen_product_id'] as String?;
    final snap = (item.data['chosen_snapshot'] as Map?)
        ?.cast<String, Object?>();
    final note = TextStyle(color: Tokens.ink3);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (chosen != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                const HintTag(
                  '已定选',
                  icon: Icons.task_alt,
                  tone: HintTone.success,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    [
                      snap?['name'],
                      snap?['brand'],
                      snap?['model'],
                    ].whereType<String>().join(' '),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () => state.write((s) => s.clearChoice(item.id)),
                  child: const Text('取消定选'),
                ),
              ],
            ),
          ),
        if (cls == null)
          Text('先选择设备类别，才能在物料库里匹配。', style: note)
        else if (cs.isEmpty)
          Text('这一项没有可自动比较的条款，可以在上面给条款添加条件。', style: note)
        else ...[
          if (open > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: HintText(
                '还有 $open 条条款没核对，匹配结果仅供参考。',
                icon: Icons.info_outline,
              ),
            ),
          () {
            final result = state.store.matchSpec(cls, cs);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MatchSummary(result: result, cs: cs),
                const SizedBox(height: 10),
                MatchMatrix(
                  state: state,
                  result: result,
                  cs: cs,
                  chosenId: chosen,
                  chosenBefore: state.store.chosenCounts(cls),
                  onChoose: (c) {
                    final problem = state.write(
                      (s) => s.chooseProduct(item.id, c.id),
                    );
                    if (problem != null) toast(context, problem);
                  },
                ),
              ],
            );
          }(),
        ],
      ],
    );
  }
}

class _ClauseCard extends StatefulWidget {
  const _ClauseCard({
    super.key,
    required this.clause,
    required this.classCode,
    required this.answer,
    required this.onChanged,
    required this.onAnswer,
  });
  final SpecClause clause;
  final String? classCode;

  /// The snapshot row once a material is chosen.
  final Map<String, Object?>? answer;
  final ValueChanged<SpecClause> onChanged;
  final void Function(String? text, Outcome? outcome) onAnswer;

  @override
  State<_ClauseCard> createState() => _ClauseCardState();
}

class _ClauseCardState extends State<_ClauseCard> {
  late final response = TextEditingController(
    text: widget.answer?['response'] as String? ?? '',
  );

  @override
  void dispose() {
    response.dispose();
    super.dispose();
  }

  SpecClause get c => widget.clause;

  Future<void> _edit([int? index]) async {
    final cls = widget.classCode;
    if (cls == null) return;
    final old = index == null ? null : c.constraints[index];
    final next = await showAppDialog<SpecConstraint>(
      context: context,
      builder: (_) => _ConstraintDialog(classCode: cls, initial: old),
    );
    if (next == null) return;
    final list = [...c.constraints];
    index == null ? list.add(next) : list[index] = next;
    widget.onChanged(c.copyWith(constraints: list, by: 'manual'));
  }

  @override
  Widget build(BuildContext context) {
    final answer = widget.answer;
    final outcome = answer?['outcome'] == null
        ? null
        : Outcome.values.byName(answer!['outcome']! as String);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
      decoration: BoxDecoration(
        color: Tokens.surface,
        // Amber only where the reading needs a look, not every unchecked row.
        border: Border.all(
          color: c.hint != null && !c.reviewed ? Tokens.amber : Tokens.rule,
        ),
        borderRadius: BorderRadius.circular(Tokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PopupMenuButton<ClauseMark>(
                tooltip: '条款类别',
                initialValue: c.mark,
                onSelected: (m) => widget.onChanged(c.copyWith(mark: m)),
                itemBuilder: (_) => [
                  for (final m in ClauseMark.values)
                    PopupMenuItem(value: m, child: Text(markLabels[m]!)),
                ],
                child: Padding(
                  padding: const EdgeInsets.only(top: 2, right: 8),
                  child: Text(
                    c.mark == ClauseMark.none ? '—' : markPrefix(c.mark).trim(),
                    style: TextStyle(
                      color: c.mark == ClauseMark.none
                          ? Tokens.ink3
                          : Tokens.red,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Expanded(child: SelectableText(c.text)),
              Tooltip(
                message: c.reviewed ? '已核对' : '标为已核对',
                child: Checkbox(
                  value: c.reviewed,
                  onChanged: (v) => widget.onChanged(c.copyWith(reviewed: v)),
                ),
              ),
            ],
          ),
          if (c.hint != null && !c.reviewed)
            Padding(
              padding: const EdgeInsets.only(left: 22, bottom: 4),
              child: HintText(c.hint!, icon: Icons.warning_amber_rounded),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 22),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (c.isText)
                  Text('文字条款，需人工判断', style: TextStyle(color: Tokens.ink3)),
                for (final (i, k) in c.constraints.indexed)
                  InputChip(
                    label: Text(k.describe()),
                    tooltip: k.text == null ? null : '原文：${k.text}',
                    onPressed: () => _edit(i),
                    onDeleted: () => widget.onChanged(
                      c.copyWith(
                        constraints: [...c.constraints]..removeAt(i),
                        by: 'manual',
                      ),
                    ),
                  ),
                if (widget.classCode != null)
                  ActionChip(
                    avatar: const AppIcon(Icons.add, size: 16),
                    label: const Text('添加条件'),
                    onPressed: () => _edit(),
                  ),
              ],
            ),
          ),
          if (c.isText && answer != null)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 320,
                    child: TextField(
                      controller: response,
                      decoration: const InputDecoration(
                        labelText: '响应（写具体内容，不写"满足"）',
                        isDense: true,
                      ),
                      onSubmitted: (t) => widget.onAnswer(t, outcome),
                    ),
                  ),
                  SizedBox(
                    width: 130,
                    child: DropdownButtonFormField<Outcome?>(
                      initialValue: outcome,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '偏离',
                        isDense: true,
                      ),
                      items: [
                        for (final o in Outcome.values)
                          DropdownMenuItem(
                            value: o,
                            child: Text(deviationLabels[o]!),
                          ),
                      ],
                      onChanged: (o) => widget.onAnswer(response.text, o),
                    ),
                  ),
                  TextButton(
                    onPressed: () => widget.onAnswer(response.text, outcome),
                    child: const Text('保存响应'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ConstraintDialog extends StatefulWidget {
  const _ConstraintDialog({required this.classCode, this.initial});
  final String classCode;
  final SpecConstraint? initial;

  @override
  State<_ConstraintDialog> createState() => _ConstraintDialogState();
}

class _ConstraintDialogState extends State<_ConstraintDialog> {
  late final draft = widget.initial == null
      ? ConstraintDraft(null, null)
      : ConstraintDraft.of(widget.initial!);

  @override
  void dispose() {
    draft.text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    SpecConstraint? result;
    try {
      result = draft.constraint(evidence: widget.initial?.text);
    } on FormatException {
      result = null;
    }
    return AlertDialog(
      title: Text(widget.initial == null ? '添加条件' : '修改条件'),
      content: SizedBox(
        width: 620,
        child: ConstraintFields(
          draft: draft,
          classCode: widget.classCode,
          showMark: false,
          onChanged: () => setState(() {}),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: result == null
              ? null
              : () => Navigator.of(context).pop(result),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
