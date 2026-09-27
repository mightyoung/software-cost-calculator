import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/format.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';

/// Shows lines whose best usable quotation changed and applies the chosen
/// ones. Hand-entered estimates start unchecked.
Future<void> showRefreshPrices(
  BuildContext context,
  AppState state,
  String projectId,
) async {
  final plan = state.store.refreshPlan(projectId);
  if (plan.isEmpty) return toast(context, '所有材料行已经采用当前最优的有效报价');
  final applied = await showDialog<int>(
    context: context,
    builder: (_) => _RefreshDialog(state: state, plan: plan),
  );
  if (applied != null && context.mounted) toast(context, '已更新 $applied 行');
}

class _RefreshDialog extends StatefulWidget {
  const _RefreshDialog({required this.state, required this.plan});
  final AppState state;
  final List<RefreshLine> plan;

  @override
  State<_RefreshDialog> createState() => _RefreshDialogState();
}

class _RefreshDialogState extends State<_RefreshDialog> {
  late final chosen = {
    for (final l in widget.plan)
      if (!l.manual) l.itemId,
  };
  String? error;

  Store get store => widget.state.store;

  String _name(RefreshLine l) {
    final p = store.get('product', l.item['product_id']! as String)?.data;
    return [p?['name'], p?['model']].whereType<String>().join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final picked = [
      for (final l in widget.plan)
        if (chosen.contains(l.itemId)) l,
    ];
    final delta = picked.fold(
      BigInt.zero,
      (sum, l) =>
          sum +
          // multiply() rounds non-negative values only.
          multiply(micros(l.item['qty']! as String), micros(l.newCost)) -
          multiply(micros(l.item['qty']! as String), micros(l.currentCost)),
    );
    return AlertDialog(
      title: const Text('按当前最优价刷新'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '下面的行有更合适的有效报价（已定标的优先，其次有效单价最低）。手填估价的行默认不勾选。',
              style: TextStyle(color: Tokens.ink2),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final l in widget.plan)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: chosen.contains(l.itemId),
                      onChanged: (on) => setState(
                        () => on!
                            ? chosen.add(l.itemId)
                            : chosen.remove(l.itemId),
                      ),
                      title: Text(_name(l)),
                      subtitle: Text(
                        [
                          '${money(l.currentCost)} → ${money(l.newCost)}',
                          store
                                      .get(
                                        'supplier',
                                        l.option.data['supplier_id']! as String,
                                      )
                                      ?.data['name']
                                  as String? ??
                              '',
                          if (l.option.awarded) '已定标',
                          if (l.manual) '现为手填估价',
                          if (l.option.data['extra_cost'] != null)
                            '另有附加费用 ${money(l.option.data['extra_cost'] as String?)}',
                        ].join(' · '),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '选中 ${picked.length} 行，成本合计变化 '
              '${delta.isNegative ? '' : '+'}${money(fromMicros(delta), prefix: '¥')}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Tokens.red)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: picked.isEmpty
              ? null
              : () {
                  final err = widget.state.write((s) => s.applyRefresh(picked));
                  if (err != null) return setState(() => error = err);
                  Navigator.pop(context, picked.length);
                },
          child: const Text('更新选中的行'),
        ),
      ],
    );
  }
}
