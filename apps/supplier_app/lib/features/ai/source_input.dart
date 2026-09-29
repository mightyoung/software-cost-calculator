import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/errors.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';

/// Paste-or-pick-Excel input shared by the AI flows. The caller owns the
/// text controller and the run state.
class SourceInput extends StatelessWidget {
  const SourceInput({
    super.key,
    required this.text,
    required this.intro,
    required this.example,
    required this.startLabel,
    required this.hasKey,
    required this.fileName,
    required this.error,
    required this.progress,
    required this.onFile,
    required this.onStart,
    required this.onCancel,
    this.extra,
  });
  final TextEditingController text;
  final String intro, example, startLabel;
  final bool? hasKey;
  final String? fileName, error, progress;
  final void Function(String name, Uint8List bytes, String? error) onFile;
  final VoidCallback onStart, onCancel;
  final Widget? extra;

  Future<void> _pickExcel(BuildContext context) async {
    final file = await pickBytesForUi(context, ['xlsx']);
    if (file == null || !context.mounted) return;
    try {
      text.text = workbookText(readXlsx(file.bytes));
      onFile(file.name, file.bytes, null);
    } on FormatException catch (e) {
      onFile(
        file.name,
        file.bytes,
        '无法读取 ${file.name}：${friendlyError(e.message)}',
      );
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(intro, style: TextStyle(color: Tokens.ink2, height: 1.6)),
        if (hasKey == false) ...[
          const SizedBox(height: 10),
          const HintText(
            '还没有配置 AI 服务：在 设置 › AI 接入 中填写 API Key。',
            icon: Icons.info_outline,
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: progress == null ? () => _pickExcel(context) : null,
              icon: const AppIcon(Icons.table_view_outlined, size: 18),
              label: const Text('选择 Excel 文件'),
            ),
            if (fileName != null)
              Text('已读取：$fileName', style: TextStyle(color: Tokens.ink2)),
            if (extra != null) ...[const SizedBox(width: 12), extra!],
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: TextField(
            controller: text,
            expands: true,
            maxLines: null,
            textAlignVertical: TextAlignVertical.top,
            enabled: progress == null,
            decoration: InputDecoration(hintText: example),
          ),
        ),
        const SizedBox(height: 12),
        if (error != null) ...[
          Text(error!, style: TextStyle(color: Tokens.red)),
          const SizedBox(height: 8),
        ],
        if (progress != null) ...[
          Text(progress!, style: TextStyle(color: Tokens.ink2)),
          const SizedBox(height: 6),
          const TaskProgress(),
          const SizedBox(height: 10),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (progress != null)
              OutlinedButton(onPressed: onCancel, child: const Text('取消'))
            else
              FilledButton.icon(
                onPressed: onStart,
                icon: const AppIcon(Icons.arrow_forward, size: 18),
                label: Text(startLabel),
              ),
          ],
        ),
      ],
    ),
  );
}

/// Numbered step indicator for the AI flows' app bars.
class StepsBar extends StatelessWidget {
  const StepsBar({super.key, required this.labels, required this.current});
  final List<String> labels;
  final int current;

  @override
  Widget build(BuildContext context) {
    Widget step(int i, String label) {
      final done = i < current, on = i == current;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? Tokens.accent : Colors.transparent,
              border: Border.all(
                color: done
                    ? Tokens.accent
                    : (on ? Tokens.ink : Tokens.ruleStrong),
              ),
            ),
            child: done
                ? const AppIcon(Icons.check, size: 13, color: Colors.white)
                : Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: 12,
                      color: on ? Tokens.ink : Tokens.ink3,
                    ),
                  ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: on ? Tokens.ink : Tokens.ink3,
              fontWeight: on ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0)
            Container(
              width: 28,
              height: 1,
              margin: const EdgeInsets.symmetric(horizontal: 10),
              color: Tokens.ruleStrong,
            ),
          step(i, labels[i]),
        ],
      ],
    );
  }
}
