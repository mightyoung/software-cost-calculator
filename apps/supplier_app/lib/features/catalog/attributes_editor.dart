import 'package:flutter/material.dart';

import '../../widgets/app_icon.dart';
import '../../app/theme.dart';

typedef AttributeRow = (
  TextEditingController name,
  TextEditingController value,
);

/// Key attributes of a material ("流量" → "50m³/h"). [suggestions] are names
/// other materials of the same category use.
class AttributesEditor extends StatelessWidget {
  const AttributesEditor({
    super.key,
    required this.rows,
    required this.suggestions,
    required this.onAdd,
    required this.onRemove,
    required this.onChanged,
  });
  final List<AttributeRow> rows;
  final List<String> suggestions;
  final ValueChanged<String?> onAdd;
  final ValueChanged<int> onRemove;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final used = {for (final r in rows) r.$1.text.trim()};
    final open = [
      for (final s in suggestions)
        if (!used.contains(s)) s,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text('关键属性', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '区分同名物料的参数，如 流量、扬程、材质；查重和搜索都会用到',
                style: TextStyle(fontSize: 12, color: Tokens.ink3),
              ),
            ),
            TextButton.icon(
              onPressed: () => onAdd(null),
              icon: const AppIcon(Icons.add, size: 16),
              label: const Text('添加'),
            ),
          ],
        ),
        for (var i = 0; i < rows.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: rows[i].$1,
                    decoration: const InputDecoration(hintText: '属性名'),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: rows[i].$2,
                    decoration: const InputDecoration(hintText: '值'),
                    onChanged: (_) => onChanged(),
                  ),
                ),
                IconButton(
                  tooltip: '删除',
                  icon: const AppIcon(Icons.close, size: 16),
                  onPressed: () => onRemove(i),
                ),
              ],
            ),
          ),
        if (open.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('同类常用：', style: TextStyle(fontSize: 12, color: Tokens.ink3)),
              for (final s in open.take(6))
                ActionChip(
                  avatar: const AppIcon(Icons.add, size: 14),
                  label: Text(s),
                  onPressed: () => onAdd(s),
                ),
            ],
          ),
      ],
    );
  }
}
