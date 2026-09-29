import 'package:flutter/material.dart';

import '../../widgets/app_icon.dart';
import '../../app/theme.dart';

typedef TierRow = (TextEditingController qty, TextEditingController price);

/// "From this quantity, this unit price" steps of one quotation.
class TiersEditor extends StatelessWidget {
  const TiersEditor({
    super.key,
    required this.rows,
    required this.unit,
    required this.onAdd,
    required this.onRemove,
  });
  final List<TierRow> rows;
  final String unit;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              rows.isEmpty ? '阶梯价：买得多单价更低时填写' : '阶梯价：需求数量达到某档时按该档单价计入预算和比价',
              style: TextStyle(fontSize: 12, color: Tokens.ink3),
            ),
          ),
          TextButton.icon(
            onPressed: rows.length >= 10 ? null : onAdd,
            icon: const AppIcon(Icons.add, size: 16),
            label: const Text('添加一档'),
          ),
        ],
      ),
      for (final (i, (qty, price)) in rows.indexed)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: qty,
                  decoration: InputDecoration(labelText: '数量达到（$unit）'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: price,
                  decoration: const InputDecoration(labelText: '单价'),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
              ),
              IconButton(
                tooltip: '删除这一档',
                icon: const AppIcon(Icons.close, size: 16),
                onPressed: () => onRemove(i),
              ),
            ],
          ),
        ),
    ],
  );
}
