import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';
import 'spec_request_page.dart';

/// 导入技术要求: an Excel sheet, pasted text or the project's lines still
/// to be inquired, read into items and clauses, then opened for review.
Future<void> showSpecImport(
  BuildContext context,
  AppState state, {
  String? projectId,
}) async {
  final id = await showDialog<String>(
    context: context,
    builder: (_) => _SpecImportDialog(state: state, projectId: projectId),
  );
  if (id != null && context.mounted) await showSpecRequest(context, state, id);
}

class _SpecImportDialog extends StatefulWidget {
  const _SpecImportDialog({required this.state, this.projectId});
  final AppState state;
  final String? projectId;

  @override
  State<_SpecImportDialog> createState() => _SpecImportDialogState();
}

class _SpecImportDialogState extends State<_SpecImportDialog> {
  late final title = TextEditingController(text: _defaultTitle());
  final text = TextEditingController();
  List<SpecItemDraft> drafts = const [];
  String? source, error;

  String _defaultTitle() {
    final p = widget.projectId == null
        ? null
        : widget.state.store.get('project', widget.projectId!)?.data;
    return p == null ? '技术要求 ${today()}' : '${p['name']} 技术要求';
  }

  @override
  void dispose() {
    title.dispose();
    text.dispose();
    super.dispose();
  }

  Future<void> _pickExcel() async {
    final file = await pickBytes(['xlsx']);
    if (file == null) return;
    setState(() {
      text.clear();
      try {
        final items = specItemsFromWorkbook(readXlsx(file.bytes));
        drafts = items ?? const [];
        source = file.name;
        error = items == null
            ? '${file.name} 里没有找到「设备名称」和「技术要求 / 主要指标要求」这两列。'
            : null;
      } on FormatException catch (e) {
        drafts = const [];
        error = '无法读取 ${file.name}：${friendlyError(e.message)}';
      }
    });
  }

  void _fromProject() => setState(() {
    text.clear();
    drafts = widget.state.store.draftsFromProject(widget.projectId!);
    source = '项目待询价行';
    error = drafts.isEmpty ? '这个项目没有待询价（还没选物料）的物料行。' : null;
  });

  void _paste(String t) => setState(() {
    drafts = t.trim().isEmpty ? const [] : specItemsFromText(t);
    source = '粘贴文本';
    error = null;
  });

  void _import() {
    String? id;
    final problem = widget.state.write(
      (s) => id = s.createSpecRequest(
        title.text.trim().isEmpty ? _defaultTitle() : title.text.trim(),
        drafts,
        projectId: widget.projectId,
        sourceName: source,
      ),
    );
    if (problem != null) return setState(() => error = problem);
    Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final clauses = [for (final d in drafts) ...d.clauses];
    final flagged = clauses.where((c) => c.hint != null).length;
    final textOnly = clauses.where((c) => c.isText).length;
    return AlertDialog(
      title: const Text('导入技术要求'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '每台设备一项，要求按条款切分后自动读成可比较的条件；读不准的条款会标出来，导入后逐条核对。',
                style: TextStyle(color: Tokens.ink2, height: 1.5),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: '标题'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickExcel,
                    icon: const Icon(Icons.table_view_outlined, size: 18),
                    label: const Text('选择 Excel 文件'),
                  ),
                  if (widget.projectId != null)
                    OutlinedButton.icon(
                      onPressed: _fromProject,
                      icon: const Icon(Icons.playlist_add_check, size: 18),
                      label: const Text('用本项目待询价的物料行'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: text,
                minLines: 5,
                maxLines: 10,
                decoration: const InputDecoration(
                  labelText: '或粘贴文字',
                  hintText:
                      '从 Excel 复制整张表，或按"设备名称 + 换行 + 要求"粘贴，设备之间空一行。例如：\n'
                      '温湿度传感器\n（1）测量范围：温度 -20℃~+80℃\n（2）防护等级不低于 IP65',
                  alignLabelWithHint: true,
                ),
                onChanged: _paste,
              ),
              const SizedBox(height: 12),
              if (error != null)
                HintText(error!, icon: Icons.error_outline)
              else if (drafts.isNotEmpty) ...[
                Text(
                  '识别出 ${drafts.length} 项设备、${clauses.length} 条条款'
                  '${flagged > 0 ? '，其中 $flagged 条需要核对' : ''}'
                  '${textOnly > 0 ? '，$textOnly 条为文字条款（需人工判断）' : ''}。',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                for (final d in drafts.take(8))
                  Text(
                    '· ${d.name.isEmpty ? '（未命名）' : d.name}'
                    '　${d.specClass == null ? '类别待定' : specClass(d.specClass!)!.label}'
                    '　${d.clauses.length} 条',
                    style: TextStyle(color: Tokens.ink2),
                  ),
                if (drafts.length > 8)
                  Text(
                    '…… 还有 ${drafts.length - 8} 项',
                    style: TextStyle(color: Tokens.ink3),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: drafts.isEmpty ? null : _import,
          child: const Text('导入并核对'),
        ),
      ],
    );
  }
}
