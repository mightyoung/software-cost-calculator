import 'package:flutter/material.dart';
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
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('关键属性转结构化参数'),
      content: SizedBox(
        width: 560,
        height: MediaQuery.sizeOf(context).height * .6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${plans.length} 个物料：设置参数模板 $classes 个，转换参数 $params 项。'
              '转换后的参数标为"未确认"，原文保存为依据；识别不了的属性保持原样。',
              style: TextStyle(color: Tokens.ink2),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final p in plans)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: Tokens.rule)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${p.name} · ${specClass(p.classCode)!.label}'
                            '${p.newClass ? '（按名称识别）' : ''}',
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                          for (final x in p.params)
                            Text(
                              '${x.attribute}「${x.text}」→ ${x.property.label} '
                              '${formatParamValue(x.property, x.value)}',
                              style: TextStyle(
                                fontSize: 12,
                                color: Tokens.ink2,
                              ),
                            ),
                          if (p.kept.isNotEmpty)
                            Text(
                              '保持原样：${p.kept.join('、')}',
                              style: TextStyle(
                                fontSize: 12,
                                color: Tokens.ink3,
                              ),
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
          child: const Text('确认转换'),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  late int n;
  final err = state.write((s) => n = s.applyAttributeMigration(plans));
  toast(context, err ?? '已转换 $n 项参数（未确认），可在物料详情里核对');
}
