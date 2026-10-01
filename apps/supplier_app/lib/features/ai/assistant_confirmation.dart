import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

Future<bool> confirmAssistantAction(
  BuildContext context,
  AssistantActionPreview preview,
  AiCancellation cancellation,
) async {
  cancellation.check();
  return await showDialog<bool>(
        context: context,
        builder: (_) => _ActionDialog(preview, cancellation),
      ) ??
      false;
}

Future<bool> confirmAssistantNetwork(
  BuildContext context,
  String name,
  Map<String, Object?> arguments,
  AiCancellation cancellation,
) async {
  cancellation.check();
  return await showDialog<bool>(
        context: context,
        builder: (_) => _ActionDialog(
          null,
          cancellation,
          networkTitle: name == 'web_search' ? '确认联网搜索' : '确认读取网页',
          networkDetails: name == 'web_search'
              ? '${arguments['query'] ?? ''}'
              : '${arguments['url'] ?? ''}',
        ),
      ) ??
      false;
}

class _ActionDialog extends StatefulWidget {
  const _ActionDialog(
    this.preview,
    this.cancellation, {
    this.networkTitle,
    this.networkDetails,
  });
  final AssistantActionPreview? preview;
  final AiCancellation cancellation;
  final String? networkTitle, networkDetails;

  @override
  State<_ActionDialog> createState() => _ActionDialogState();
}

class _ActionDialogState extends State<_ActionDialog> {
  late final void Function() _unregister;

  @override
  void initState() {
    super.initState();
    _unregister = widget.cancellation.onCancel(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).pop(false);
        }
      });
    });
  }

  @override
  void dispose() {
    _unregister();
    super.dispose();
  }

  String _value(Object? value) {
    if (value == null || value == '') return '空';
    if (value is bool) return value ? '是' : '否';
    if (value is String) return value;
    return const JsonEncoder.withIndent('  ').convert(value);
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    if (preview == null) {
      return AlertDialog(
        scrollable: true,
        title: Text(widget.networkTitle!),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('以下搜索词或网址将发送给公开网站。请先核对是否包含不宜外发的信息。'),
            const SizedBox(height: 12),
            SelectableText(widget.networkDetails!),
          ],
        ),
        actions: _actions('允许此次请求'),
      );
    }
    final operation = switch (preview.operation) {
      'create_record' => '新增',
      'update_record' => '修改',
      'delete_record' => '删除',
      'restore_record' => '恢复',
      _ => '操作',
    };
    final type = ontology[preview.type];
    return AlertDialog(
      scrollable: true,
      title: Text('确认$operation${type?.label ?? preview.type}'),
      content: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(preview.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            if (preview.operation == 'delete_record') ...[
              const Text('记录将移入回收站。相关记录会保留原有引用。'),
              for (final entry in preview.affectedReferences.entries)
                Text(
                  '${ontology[entry.key]?.label ?? entry.key}：${entry.value} 条关联',
                ),
            ],
            if (preview.operation == 'restore_record')
              const Text('将恢复这条记录，使它重新出现在查询结果中。'),
            for (final entry
                in (preview.operation == 'delete_record' ||
                            preview.operation == 'restore_record'
                        ? preview.before
                        : preview.changes)
                    .entries) ...[
              const SizedBox(height: 10),
              Text(
                type?.field(entry.key)?.label ?? entry.key,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              if (entry.value is Map &&
                  (entry.value as Map).containsKey('before')) ...[
                if (preview.operation == 'update_record')
                  SelectableText(
                    '原值：${_value((entry.value as Map)['before'])}',
                  ),
                SelectableText('新值：${_value((entry.value as Map)['after'])}'),
              ] else
                SelectableText(_value(entry.value)),
            ],
            const SizedBox(height: 16),
            const Text('确认只适用于本次显示的变更；数据变化后需重新确认。'),
          ],
        ),
      ),
      actions: _actions('确认$operation'),
    );
  }

  List<Widget> _actions(String label) => [
    TextButton(
      onPressed: () => widget.cancellation.cancel(),
      child: const Text('停止任务'),
    ),
    TextButton(
      onPressed: () => Navigator.of(context).pop(false),
      child: const Text('拒绝'),
    ),
    FilledButton(
      onPressed: () {
        if (!widget.cancellation.isCancelled) {
          Navigator.of(context).pop(true);
        }
      },
      child: Text(label),
    ),
  ];
}
