import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/theme.dart';

String duplicateLabel(Map<String, Object?> d) =>
    [d['name'], d['brand'], d['model']].whereType<String>().join(' · ');

/// Existing records that look like the one being edited. [onMerge] is set
/// when editing an existing record; [onOpen] when creating a new one.
class DuplicateHints extends StatelessWidget {
  const DuplicateHints({
    super.key,
    required this.duplicates,
    this.onMerge,
    this.onOpen,
  });
  final List<Duplicate> duplicates;
  final ValueChanged<Duplicate>? onMerge, onOpen;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
    decoration: BoxDecoration(
      color: Tokens.amberBg,
      borderRadius: BorderRadius.circular(Tokens.radius),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '可能已经存在',
          style: TextStyle(fontWeight: FontWeight.w600, color: Tokens.amber),
        ),
        for (final d in duplicates.take(5))
          Row(
            children: [
              Text(
                d.level == Similarity.same ? '相同' : '相似',
                style: TextStyle(
                  fontSize: 12,
                  color: d.level == Similarity.same ? Tokens.red : Tokens.ink3,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  duplicateLabel(d.hit.data),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (onMerge != null)
                TextButton(
                  onPressed: () => onMerge!(d),
                  child: const Text('合并到这条'),
                ),
              if (onOpen != null)
                TextButton(
                  onPressed: () => onOpen!(d),
                  child: const Text('打开这条'),
                ),
            ],
          ),
      ],
    ),
  );
}
