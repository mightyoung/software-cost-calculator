import 'package:flutter/material.dart';

import '../../app/workspace.dart';
import '../../platform/import_cancellation.dart';

class BundleSyncPage extends StatefulWidget {
  const BundleSyncPage({super.key, required this.actions});
  final WorkspaceBundleActions actions;

  @override
  State<BundleSyncPage> createState() => _BundleSyncPageState();
}

class _BundleSyncPageState extends State<BundleSyncPage> {
  final _resume = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _error = false;
  WorkspaceBundlePreview? _retryPreview;
  ImportCancellation? _parsing;

  @override
  void dispose() {
    _resume.dispose();
    super.dispose();
  }

  Future<String?> _path() async {
    if (!widget.actions.importNeedsPath) return null;
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择完整同步包'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '同步包完整路径',
            hintText: r'C:\资料\supplier.bundle.zip',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('读取并验证'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _import() async {
    final path = await _path();
    if (widget.actions.importNeedsPath && (path == null || path.isEmpty)) {
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });
    WorkspaceBundlePreview? preview;
    try {
      _parsing = ImportCancellation();
      preview = await widget.actions.prepareImport(
        sourcePath: path,
        cancellation: _parsing,
      );
      _parsing!.check();
      _parsing = null;
      await _review(preview);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = true;
          _message = '完整同步未完成：$error';
        });
      }
    } finally {
      _parsing = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _review(WorkspaceBundlePreview preview) async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认完整同步'),
        content: Text(
          '文件：${preview.sourceName}\n'
          '修订：${preview.revisionCount}\n'
          '源摘要：${preview.sourceDigest}\n\n'
          '全部分卷、闭包、投影和本地并集已经验证。确认后先生成当前资料库备份，再在一个事务中提交。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('备份并提交'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      await widget.actions.cancelImport(preview);
      _retryPreview = null;
      if (mounted) setState(() => _message = '完整同步已取消，没有提交业务数据。');
      return;
    }
    _retryPreview = preview;
    final result = await widget.actions.commitImport(preview);
    _retryPreview = null;
    if (mounted) setState(() => _message = result);
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      final result = await widget.actions.commitImport(_retryPreview!);
      _retryPreview = null;
      if (mounted) {
        setState(() {
          _message = result;
          _error = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = '完整同步未完成，可重试：$error';
          _error = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resumeImport() async {
    final id = _resume.text.trim();
    if (id.isEmpty) return;
    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });
    try {
      await _review(await widget.actions.resumeImport(id));
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = true;
          _message = '同步任务未恢复：$error';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });
    try {
      final result = await widget.actions.exportBundle();
      if (mounted) setState(() => _message = result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = true;
          _message = '完整同步包未生成：$error';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('完整同步')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('分卷完整历史', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('完整同步包用于设备之间交换全部因果历史。业务 Excel 仍用于日常编辑，两种文件不能互相替代。'),
        const SizedBox(height: 20),
        if (_busy) const LinearProgressIndicator(semanticsLabel: '完整同步处理中'),
        if (_busy && _parsing != null)
          TextButton(
            onPressed: _parsing!.requested
                ? null
                : () async {
                    final pending = _parsing!;
                    setState(() {
                      pending.requested = true;
                      _message = '已请求取消解析，不会提交业务数据。';
                    });
                    try {
                      await pending.cancel();
                    } catch (error) {
                      if (mounted) {
                        setState(() => _message = '已停止读取，任务清理未完成：$error');
                      }
                    }
                  },
            child: const Text('取消解析'),
          ),
        if (_retryPreview != null && !_busy)
          FilledButton(onPressed: _retry, child: const Text('重试备份并提交')),
        if (_message != null)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                _message!,
                style: TextStyle(
                  color: _error ? Theme.of(context).colorScheme.error : null,
                ),
              ),
            ),
          ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.move_to_inbox_outlined),
            title: const Text('导入完整同步包'),
            subtitle: const Text('先验证全部分卷和本地并集，展示摘要后由你确认。'),
            trailing: FilledButton(
              onPressed: _busy ? null : _import,
              child: const Text('选择并预览'),
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.outbox_outlined),
            title: const Text('导出完整同步包'),
            subtitle: const Text('从冻结副本分页生成，整包自验成功后才发布。'),
            trailing: OutlinedButton(
              onPressed: _busy ? null : _export,
              child: const Text('生成同步包'),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _resume,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '恢复已验证的同步任务',
            hintText: '从文件任务记录复制任务编号',
          ),
          onSubmitted: (_) => _resumeImport(),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy ? null : _resumeImport,
            child: const Text('恢复预览并继续确认'),
          ),
        ),
      ],
    ),
  );
}
