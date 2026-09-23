import 'package:flutter/material.dart';

import '../../app/workspace.dart';
import '../../platform/restore_workflow.dart';
import 'alias_repair.dart';
import 'business_import_page.dart';
import 'bundle_sync_page.dart';
import 'job_history.dart';

class ExchangePage extends StatefulWidget {
  const ExchangePage({
    super.key,
    required this.workspace,
    required this.onWorkspaceReplaced,
  });
  final SupplierWorkspace workspace;
  final void Function(SupplierWorkspace workspace, {String? message})
  onWorkspaceReplaced;
  @override
  State<ExchangePage> createState() => _ExchangePageState();
}

class _ExchangePageState extends State<ExchangePage> {
  final _scroll = ScrollController();
  WorkspaceTask? _busy;
  String? _message;
  bool _error = false;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _run(WorkspaceTask task) async {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      _busy = task;
      _message = null;
      _error = false;
    });
    try {
      final receipt = await widget.workspace.perform(task);
      if (mounted) {
        setState(
          () => _message = receipt.cancelled ? '操作已取消，数据未提交。' : receipt.message,
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = true;
          _message = '操作未完成：$error';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _repairAliases(String type) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            AliasRepairPage(workspace: widget.workspace, type: type),
      ),
    );
    if (changed == true && mounted) {
      setState(() {
        _error = false;
        _message = '关联修复已提交；来源记录保留完整历史并重定向到保留记录。';
      });
    }
  }

  Future<void> _restore() async {
    String? sourcePath;
    if (widget.workspace.restoreNeedsPath) {
      final controller = TextEditingController();
      sourcePath = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('选择完整备份'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '备份文件路径',
              hintText: r'C:\资料\supplier.backup',
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
      if (sourcePath == null || sourcePath.isEmpty) return;
    }
    setState(() {
      _busy = WorkspaceTask.restoreBackup;
      _message = null;
      _error = false;
    });
    final flow = widget.workspace.restoreWorkflow(sourcePath: sourcePath);
    try {
      final preview = await flow.prepare();
      if (!mounted) return;
      final counts = preview.summary.header.counts.values.fold<int>(
        0,
        (sum, value) => sum + value,
      );
      final version = preview.summary.header.version;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认恢复完整备份'),
          content: Text(
            '文件：${preview.sourceName}\n'
            '校验值：${preview.summary.digest}\n'
            '记录行：$counts\n'
            '来源版本：epoch ${version.activeEpoch} / generation ${version.generation}\n\n'
            '确认后将切换资料库并重新打开。当前资料库会先生成安全备份。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认恢复'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        flow.cancel();
        if (mounted) setState(() => _message = '恢复已取消，当前资料库未切换。');
        return;
      }
      final replacement = await flow.confirmAndActivate(preview);
      widget.onWorkspaceReplaced(replacement, message: '完整备份已验证、切换并重新打开。');
    } on RestoreActivationFailure<SupplierWorkspace> catch (failure) {
      if (failure.recoveredWorkspace case final replacement?) {
        widget.onWorkspaceReplaced(
          replacement,
          message: '恢复未完成，已重新打开可用资料库：$failure',
        );
      } else if (mounted) {
        setState(() {
          _error = true;
          _message = '$failure';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = true;
          _message = '恢复未完成：$error';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _businessImport() async {
    final adapter = widget.workspace.businessImport;
    if (adapter == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => BusinessImportPage(adapter: adapter)),
    );
    if (mounted) {
      setState(() {
        _error = false;
        _message = '业务 Excel 任务已返回；可在任务记录中核对提交、取消或失败状态。';
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListView(
    controller: _scroll,
    padding: const EdgeInsets.all(24),
    children: [
      Text('导入导出与备份', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 8),
      const Text('业务 Excel 用于整理报价；完整备份用于保存全部历史和导入记录。'),
      const SizedBox(height: 24),
      if (_busy != null) ...[
        const LinearProgressIndicator(semanticsLabel: '文件操作进行中'),
        const SizedBox(height: 8),
        const Text('操作进行中，请在文件窗口完成选择。'),
      ],
      if (_message != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Semantics(
            liveRegion: true,
            child: Text(
              _message!,
              style: TextStyle(
                color: _error ? Theme.of(context).colorScheme.error : null,
              ),
            ),
          ),
        ),
      for (final item in [
        (
          WorkspaceTask.importWorkbook,
          '导入业务 Excel',
          '选择资料模式、映射列并预览，确认后才写入。',
          Icons.file_open_outlined,
        ),
        (
          WorkspaceTask.exportWorkbook,
          '导出业务 Excel',
          '导出已确认的业务字段，保留原始编号和精确金额。',
          Icons.file_download_outlined,
        ),
        (
          WorkspaceTask.createBackup,
          '生成完整备份',
          '校验完成后才报告生成成功；浏览器下载状态单独显示。',
          Icons.backup_outlined,
        ),
        (
          WorkspaceTask.restoreBackup,
          '恢复备份',
          '先验证备份，再确认切换；当前数据保留至重新打开校验完成。',
          Icons.restore,
        ),
      ]) ...[
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(item.$4),
          title: Text(item.$2),
          subtitle: Text(item.$3),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed:
                _busy != null ||
                    (item.$1 == WorkspaceTask.importWorkbook &&
                        widget.workspace.businessImport == null)
                ? null
                : item.$1 == WorkspaceTask.restoreBackup
                ? _restore
                : item.$1 == WorkspaceTask.importWorkbook
                ? _businessImport
                : () => _run(item.$1),
            child: Text(item.$2),
          ),
        ),
        const SizedBox(height: 20),
      ],
      const Divider(height: 40),
      Text('设备间完整同步', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      const Text('同步包包含完整修订历史，所有分卷验证后才允许一次提交。'),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.tonalIcon(
          onPressed: _busy == null && widget.workspace.bundleActions != null
              ? () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => BundleSyncPage(
                      actions: widget.workspace.bundleActions!,
                    ),
                  ),
                )
              : null,
          icon: const Icon(Icons.sync_alt),
          label: const Text('打开完整同步'),
        ),
      ),
      const Divider(height: 40),
      Text('关联修复', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      const Text('合并前会重新读取两条记录及其全部当前修订。系统不会自动选择保留项。'),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            onPressed: _busy == null ? () => _repairAliases('supplier') : null,
            icon: const Icon(Icons.store_outlined),
            label: const Text('修复供应商关联'),
          ),
          OutlinedButton.icon(
            onPressed: _busy == null ? () => _repairAliases('product') : null,
            icon: const Icon(Icons.inventory_2_outlined),
            label: const Text('修复产品关联'),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _busy == null
              ? () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => JobHistoryPage(workspace: widget.workspace),
                  ),
                )
              : null,
          icon: const Icon(Icons.history),
          label: const Text('查看文件任务记录'),
        ),
      ),
    ],
  );
}
