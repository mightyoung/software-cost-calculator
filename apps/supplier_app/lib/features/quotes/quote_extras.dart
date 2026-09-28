import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';

const includeLabels = {
  'freight': '运输',
  'installation': '安装',
  'commissioning': '调试',
  'training': '培训',
};

/// "含 运输、安装 · 不含 调试、培训"; null when the quote did not say.
String? scopeText(Object? includes) {
  if (includes is! List) return null;
  final yes = [
    for (final k in quoteIncludes)
      if (includes.contains(k)) k,
  ];
  final no = [
    for (final k in quoteIncludes)
      if (!includes.contains(k)) k,
  ];
  return [
    if (yes.isNotEmpty) '含 ${yes.map((k) => includeLabels[k]).join('、')}',
    if (no.isNotEmpty) '不含 ${no.map((k) => includeLabels[k]).join('、')}',
  ].join(' · ');
}

/// What the price covers. Null (nothing chosen, "未说明") differs from an
/// empty list ("都不含").
class IncludesPicker extends StatelessWidget {
  const IncludesPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final List<String>? value;
  final ValueChanged<List<String>?> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Text('报价包含', style: TextStyle(fontSize: 12, color: Tokens.ink2)),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('未说明'),
            selected: value == null,
            showCheckmark: false,
            onSelected: (_) => onChanged(null),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 6,
        children: [
          for (final e in includeLabels.entries)
            FilterChip(
              label: Text(e.value),
              selected: value?.contains(e.key) ?? false,
              onSelected: (on) => onChanged([
                for (final k in quoteIncludes)
                  if (k == e.key ? on : (value?.contains(k) ?? false)) k,
              ]),
            ),
        ],
      ),
    ],
  );
}

/// Original documents of a quotation: add, and save a copy to look at.
class AttachmentsField extends StatelessWidget {
  const AttachmentsField({
    super.key,
    required this.state,
    required this.ids,
    required this.onChanged,
  });
  final AppState state;
  final List<String> ids;
  final ValueChanged<List<String>> onChanged;

  Future<void> _add(BuildContext context) async {
    final file = await pickBytes(const []);
    if (file == null) return;
    String? id;
    final err = state.write((s) => id = s.addAttachment(file.name, file.bytes));
    if (!context.mounted) return;
    if (err != null) return toast(context, '无法添加附件：$err');
    onChanged([...ids, id!]);
  }

  Future<void> _open(BuildContext context, Attachment a) async {
    final full = state.store.attachment(a.id);
    if (full == null) return;
    final saved = await saveBytes(a.name, full.bytes!);
    if (saved && context.mounted) toast(context, '已保存 ${a.name}');
  }

  @override
  Widget build(BuildContext context) {
    final list = state.store.attachmentsOf(ids);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('原件', style: TextStyle(fontSize: 12, color: Tokens.ink2)),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _add(context),
              icon: const Icon(Icons.attach_file, size: 16),
              label: const Text('添加报价单、截图等'),
            ),
          ],
        ),
        if (list.isEmpty)
          Text('没有原件', style: TextStyle(fontSize: 12, color: Tokens.ink3)),
        for (final a in list)
          Row(
            children: [
              Icon(Icons.description_outlined, size: 16, color: Tokens.ink3),
              const SizedBox(width: 6),
              Expanded(child: Text(a.name, overflow: TextOverflow.ellipsis)),
              Text(
                '${(a.size / 1024).ceil()} KB',
                style: TextStyle(fontSize: 12, color: Tokens.ink3),
              ),
              IconButton(
                tooltip: '另存一份查看',
                icon: const Icon(Icons.download_outlined, size: 16),
                onPressed: () => _open(context, a),
              ),
              IconButton(
                tooltip: '从这条报价移除（原件仍保留在本机）',
                icon: const Icon(Icons.close, size: 16),
                onPressed: () => onChanged([
                  for (final i in ids)
                    if (i != a.id) i,
                ]),
              ),
            ],
          ),
      ],
    );
  }
}
