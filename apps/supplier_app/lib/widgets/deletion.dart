import 'package:flutter/material.dart';
import '../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../app/app_state.dart';
import '../app/theme.dart';
import '../platform/files.dart';

/// Asks before deleting master data; says what still points at the record.
Future<bool> confirmDelete(
  BuildContext context,
  AppState state, {
  required String type,
  required String id,
  required String name,
}) async {
  final label = ontology[type]!.label;
  final refs = describeReferences(state.store.referencesTo(type, id));
  final sure = await showAppDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('删除$label「$name」？'),
      content: SizedBox(
        width: 400,
        child: Text(
          [
            if (refs.isNotEmpty) '还有 $refs引用了它；这些记录会保留，并标明"$label已删除"。',
            '删除后可以立即撤销，也可以在 设置 › 已删除的记录 中恢复。',
          ].join('\n'),
          style: const TextStyle(height: 1.6),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Tokens.red),
          onPressed: () => Navigator.pop(context, true),
          child: Text('删除$label'),
        ),
      ],
    ),
  );
  return sure == true;
}

/// Deletes and offers an undo. Returns false (after telling the user why)
/// when the delete was refused.
bool deleteWithUndo(
  BuildContext context,
  AppState state, {
  required String type,
  required String id,
  required String name,
}) {
  final messenger = ScaffoldMessenger.of(context);
  final err = state.write((s) => s.delete(type, id));
  if (err != null) {
    toast(context, '没有删除：$err');
    return false;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('已删除${ontology[type]!.label}「$name」'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () => state.write((s) => s.restore(type, id)),
        ),
      ),
    );
  return true;
}

/// Delete button for a dialog's action row: kept on the far left, away from
/// 保存.
List<Widget> dialogActions({
  required VoidCallback? onDelete,
  required String deleteLabel,
  required List<Widget> actions,
}) => [
  if (onDelete == null)
    const SizedBox.shrink()
  else
    TextButton(
      onPressed: onDelete,
      style: TextButton.styleFrom(foregroundColor: Tokens.red),
      child: Text(deleteLabel),
    ),
  Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: actions),
];

/// Deletes several records at once after asking; one undo restores all.
Future<void> deleteManyWithUndo(
  BuildContext context,
  AppState state, {
  required String type,
  required List<String> ids,
}) async {
  final label = ontology[type]!.label;
  final sure = await showAppDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('删除选中的 ${ids.length} 个$label？'),
      content: const Text('引用它们的记录会保留。删除后可以立即撤销，也可以在 设置 › 已删除的记录 中恢复。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Tokens.red),
          onPressed: () => Navigator.pop(context, true),
          child: Text('删除 ${ids.length} 个'),
        ),
      ],
    ),
  );
  if (sure != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  final err = state.write(
    (s) => s.transaction(() {
      for (final id in ids) {
        s.delete(type, id);
      }
    }),
  );
  if (err != null) return toast(context, '没有删除：$err');
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('已删除 ${ids.length} 个$label'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () => state.write(
            (s) => s.transaction(() {
              for (final id in ids) {
                s.restore(type, id);
              }
            }),
          ),
        ),
      ),
    );
}
