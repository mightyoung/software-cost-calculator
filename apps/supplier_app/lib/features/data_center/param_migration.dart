import 'package:flutter/material.dart';

import '../../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';

/// Previews turning free "关键属性" into typed parameters, then applies it.
/// Converted values are unconfirmed and keep the original text as evidence.
Future<void> showParamMigration(BuildContext context, AppState state) async {
  final plans = state.store.planAttributeMigration();
  if (plans.isEmpty) {
    return toast(context, '没有可以转换的关键属性');
  }
  final params = plans.fold(0, (n, p) => n + p.params.length);
  final classes = plans.where((p) => p.newClass).length;
  final ok = await _preview(
    context,
    title: '关键属性转结构化参数',
    summary:
        '${plans.length} 个物料：设置参数模板 $classes 个，转换参数 $params 项。'
        '转换后的参数标为"未确认"，原文保存为依据；识别不了的属性保持原样。',
    confirm: '确认转换',
    rows: [
      for (final p in plans)
        (
          '${p.name} · ${specClass(p.classCode)!.label}'
              '${p.newClass ? '（按名称识别）' : ''}',
          [
            for (final x in p.params)
              '${x.attribute}「${x.text}」→ ${x.property.label} '
                  '${formatParamValue(x.property, x.value)}',
          ],
          p.kept.isEmpty ? null : '保持原样：${p.kept.join('、')}',
        ),
    ],
  );
  if (ok != true || !context.mounted) return;
  late int n;
  final err = state.write((s) => n = s.applyAttributeMigration(plans));
  toast(context, err ?? '已转换 $n 项参数（未确认），可在物料参数表里核对');
}

const _sourceWords = {'rule': '规格说明', 'decoder': '型号解码', 'ai': 'AI'};

/// Previews parameters read from model codes (cables) and specification
/// text, then writes them unconfirmed with their evidence.
Future<void> showParamFill(BuildContext context, AppState state) async {
  final plans = state.store.planParamFill();
  final values = plans.fold(0, (n, p) => n + p.guesses.length);
  if (values == 0 && plans.every((p) => !p.newClass)) {
    return toast(context, '型号和规格说明里没有读出新的参数');
  }
  final ok = await _preview(
    context,
    title: '从型号和规格说明补全参数',
    summary:
        '${plans.length} 个物料，读出参数 $values 项；'
        '没有参数模板的按名称识别 ${plans.where((p) => p.newClass).length} 个。'
        '已有的参数不覆盖；新值标为"未确认"，原文保存为依据。',
    confirm: '写入',
    rows: [
      for (final p in plans)
        (
          '${p.name} · ${specClass(p.classCode)!.label}'
              '${p.newClass ? '（按名称识别）' : ''}',
          [
            for (final g in p.guesses)
              if (specProperty(g.property) case final prop?)
                '${prop.label} ${formatParamValue(prop, g.value)}'
                    '　← ${_sourceWords[g.source]}「${g.evidence}」',
          ],
          null,
        ),
    ],
  );
  if (ok != true || !context.mounted) return;
  late int n;
  final err = state.write((s) => n = s.applyParamFill(plans));
  toast(context, err ?? '已写入 $n 项参数（未确认），可在物料参数表里核对');
}

Future<bool?> _preview(
  BuildContext context, {
  required String title,
  required String summary,
  required String confirm,
  required List<(String, List<String>, String?)> rows,
}) => showAppDialog<bool>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: SizedBox(
      width: 600,
      height: MediaQuery.sizeOf(context).height * .6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(summary, style: TextStyle(color: Tokens.ink2)),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                for (final (head, lines, kept) in rows)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: Tokens.rule)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          head,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        for (final l in lines)
                          Text(
                            l,
                            style: TextStyle(fontSize: 12, color: Tokens.ink2),
                          ),
                        if (kept != null)
                          Text(
                            kept,
                            style: TextStyle(fontSize: 12, color: Tokens.ink3),
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
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, true),
        child: Text(confirm),
      ),
    ],
  ),
);
