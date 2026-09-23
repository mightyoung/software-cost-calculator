import 'package:flutter/material.dart';

import '../../app/workspace.dart';
import '../records/record_editor.dart';
import 'alias_repair.dart';

/// Presents every current head. No branch is chosen until the user confirms a
/// complete payload, and the final write compares the entire original head set.
class ConflictResolutionPage extends StatefulWidget {
  const ConflictResolutionPage({
    super.key,
    required this.workspace,
    required this.conflict,
  });

  final SupplierWorkspace workspace;
  final WorkspaceRecord conflict;

  @override
  State<ConflictResolutionPage> createState() => _ConflictResolutionPageState();
}

class _ConflictResolutionPageState extends State<ConflictResolutionPage> {
  late Future<List<WorkspaceConflictBranch>> _branches = _load();
  String? _selected;
  String? _error;
  bool _busy = false;

  Future<List<WorkspaceConflictBranch>> _load() => widget.workspace
      .conflictBranches(widget.conflict.type, widget.conflict.id);

  Future<void> _resolve(WorkspaceConflictBranch branch) async {
    if (branch.kind == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认保留删除状态'),
          content: const Text('将全部当前分支作为父修订提交删除。历史内容仍会保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认删除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() => _busy = true);
      try {
        await widget.workspace.delete(widget.conflict);
        if (mounted) Navigator.pop(context, true);
      } catch (error) {
        if (mounted) setState(() => _error = '提交未完成，请重新读取：$error');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    if (branch.kind == 'redirect') {
      setState(() => _busy = true);
      try {
        final target = await widget.workspace.read(
          widget.conflict.type,
          branch.payload['target_id']! as String,
        );
        if (!mounted) return;
        final saved = await Navigator.of(context).push<bool>(
          MaterialPageRoute(
            builder: (_) => AliasRepairPage(
              workspace: widget.workspace,
              type: widget.conflict.type,
              initialSource: widget.conflict,
              initialKeeper: target,
            ),
          ),
        );
        if (saved == true && mounted) Navigator.pop(context, true);
      } catch (error) {
        if (mounted) setState(() => _error = '无法准备关联修复：$error');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RecordEditor(
          workspace: widget.workspace,
          type: widget.conflict.type,
          record: WorkspaceRecord(
            type: widget.conflict.type,
            id: widget.conflict.id,
            title: '冲突处理',
            payload: branch.payload,
            heads: widget.conflict.heads,
            status: 'conflicted',
          ),
          resolving: true,
        ),
      ),
    );
    if (saved == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('处理冲突')),
    body: FutureBuilder<List<WorkspaceConflictBranch>>(
      future: _branches,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(semanticsLabel: '正在读取冲突分支'),
          );
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 36),
                  const SizedBox(height: 12),
                  Text('无法读取冲突：${snapshot.error}'),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: () => setState(() => _branches = _load()),
                    child: const Text('重新读取'),
                  ),
                ],
              ),
            ),
          );
        }
        final branches = snapshot.requireData;
        final selected = branches
            .where((item) => item.revisionId == _selected)
            .firstOrNull;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('选择完整版本', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text('并列分支都会保留在历史中。选择一个版本后仍可先编辑，再用全部当前分支作为父修订提交。'),
            const SizedBox(height: 20),
            RadioGroup<String>(
              groupValue: _selected,
              onChanged: (value) => setState(() => _selected = value),
              child: Column(
                children: [
                  for (final branch in branches)
                    Card(
                      child: Column(
                        children: [
                          RadioListTile<String>(
                            value: branch.revisionId,
                            enabled: !_busy,
                            title: Text(
                              branch.kind == 'put'
                                  ? _summary(branch.payload)
                                  : branch.kind == 'delete'
                                  ? '已删除分支'
                                  : '关联至 ${branch.payload['target_id']}',
                            ),
                            subtitle: Text(
                              '${branch.authoredAt}\n设备 ${branch.originDeviceId}\n修订 ${branch.revisionId}',
                            ),
                            isThreeLine: true,
                          ),
                          if (branch.kind == 'put')
                            ExpansionTile(
                              title: const Text('比较完整字段'),
                              children: [
                                for (final entry in branch.payload.entries)
                                  ListTile(
                                    dense: true,
                                    title: Text(
                                      fieldLabels[entry.key] ?? entry.key,
                                    ),
                                    subtitle: SelectableText(
                                      _displayValue(entry.value),
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_error != null) Text(_error!),
            FilledButton.icon(
              onPressed:
                  selected == null ||
                      _busy ||
                      widget.workspace.readOnlyReason != null
                  ? null
                  : () => _resolve(selected),
              icon: const Icon(Icons.merge_type),
              label: const Text('以此版本为基础解决冲突'),
            ),
            const SizedBox(height: 8),
            const Text('若数据库在确认前出现新分支，本次提交会被拒绝并要求重新读取。'),
          ],
        );
      },
    ),
  );
}

String _displayValue(Object? value) {
  if (value == null) return '未填写';
  if (value is Map) {
    return value.entries
        .map((entry) => '${entry.key}：${entry.value ?? '未填写'}')
        .join('\n');
  }
  if (value is List) return value.isEmpty ? '空列表' : value.join('、');
  return value.toString();
}

String _summary(Map<String, Object?> payload) {
  for (final key in ['name', 'project_name', 'project_number', 'price']) {
    final value = payload[key];
    if (value != null && value.toString().isNotEmpty) {
      return '${fieldLabels[key] ?? key}：$value';
    }
  }
  return '完整记录版本';
}
