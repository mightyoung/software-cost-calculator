import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import 'passphrase.dart';

const _typeLabels = {
  'supplier': '供应商',
  'contact': '联系人',
  'product': '物料',
  'project': '项目',
  'quotation': '报价',
  'project_item': '预算行',
  'inquiry': '询价单',
};

// Background jobs are built at top level so they capture only their
// arguments, never the page (which cannot be sent to another isolate).
Map<String, TableImport> Function(Store) _previewJob(String path) =>
    (s) => s.previewImport(path);

void Function(Store) _importJob(String path) =>
    (s) => s.importFrom(path);

Map<String, int> Function(Store) _countsJob(String path) =>
    (s) => s.snapshotCounts(path);

void Function(Store) _restoreJob(String path, String backupPath) =>
    (s) => s.replaceFrom(path, safetyBackupPath: backupPath);

/// Decrypts an encrypted file with the stored passphrase, asking when
/// there is none or it does not fit. Returns null when the user gives up.
Future<String?> _plain(
  BuildContext context,
  AppState state,
  String path,
  Directory temp,
) async {
  if (!isEncryptedExchange(path)) return path;
  String? passphrase;
  String? problem;
  try {
    passphrase = await state.exchangePassphrase();
  } on FormatException catch (e) {
    // A manually entered password is used only for this import. Outbound
    // operations still stop when secure storage cannot be read.
    problem = '${e.message}。也可输入此文件的口令，仅用于本次导入，不保存。';
  }
  while (true) {
    if (passphrase == null) {
      if (!context.mounted) return null;
      passphrase = await askPassphrase(
        context,
        title: '这份数据已加密',
        message: problem ?? '请输入对方设置的交换口令。',
      );
      if (passphrase == null) return null;
    }
    try {
      return await decryptExchange(path, passphrase, temp);
    } on ExchangeAuthenticationException {
      problem = '口令不对，或文件已损坏。请重新输入。';
      passphrase = null;
    } on FormatException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(friendlyError(e.message))));
      }
      return null;
    }
  }
}

/// Decrypts [path] when needed, previews it, and imports once confirmed, all
/// heavy steps in the background. [path] itself is left in place. `done` is
/// false only when the user backed out; `message` is for a toast.
Future<({bool done, String? message})> reviewAndImport(
  BuildContext context,
  AppState state,
  String path, {
  String title = '导入预览',
  void Function(bool busy)? onBusy,
}) async {
  final temp = Directory('${state.dataDir.path}/tmp');
  final plain = await _plain(context, state, path, temp);
  if (plain == null) return (done: false, message: null);
  try {
    if (!context.mounted) return (done: false, message: null);
    final Map<String, TableImport> preview;
    try {
      onBusy?.call(true);
      preview = await state.store.inBackground(_previewJob(plain));
    } on FormatException catch (e) {
      return (
        done: true,
        message: e.message.contains('newer version')
            ? '这份数据来自更新版本的程序，请先升级本机再导入'
            : '这不是有效的交换数据，或文件已损坏',
      );
    } finally {
      onBusy?.call(false);
    }
    if (!context.mounted) return (done: false, message: null);
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (_) => _Preview(title: title, preview: preview),
    );
    if (confirmed != true) return (done: false, message: null);
    onBusy?.call(true);
    try {
      final err = await state.writeInBackground(_importJob(plain));
      return (done: true, message: err ?? '已合并');
    } finally {
      onBusy?.call(false);
    }
  } finally {
    if (plain != path) File(plain).deleteSync();
  }
}

/// Restore an entire snapshot. This intentionally does not use merge-import:
/// records made after the snapshot, including deletions and history, disappear.
Future<({bool done, String? message})> reviewAndRestore(
  BuildContext context,
  AppState state,
  String path, {
  void Function(bool busy)? onBusy,
}) async {
  final temp = Directory('${state.dataDir.path}/tmp');
  final plain = await _plain(context, state, path, temp);
  if (plain == null) return (done: false, message: null);
  try {
    if (!context.mounted) return (done: false, message: null);
    final Map<String, int> counts;
    try {
      onBusy?.call(true);
      counts = await state.store.inBackground(_countsJob(plain));
    } on FormatException catch (e) {
      return (
        done: true,
        message: e.message.contains('newer version')
            ? '这份备份来自更新版本的程序，请先升级本机再恢复'
            : '这不是有效的备份，或文件已损坏',
      );
    } finally {
      onBusy?.call(false);
    }
    if (!context.mounted) return (done: false, message: null);
    final previewed = await showAppDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('整库恢复预览'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('备份中的有效记录：'),
              const SizedBox(height: 10),
              for (final entry in counts.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${_typeLabels[entry.key] ?? entry.key}：${entry.value}',
                  ),
                ),
              const SizedBox(height: 12),
              const Text('继续后，本机当前资料库将被这份备份完整替换。'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (previewed != true || !context.mounted) {
      return (done: false, message: null);
    }
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('确认替换整个资料库？'),
        content: const SizedBox(
          width: 440,
          child: Text(
            '备份之后新增或修改的本机数据会从当前资料库消失。恢复前会自动保存一份本机完整备份。'
            '共享文件夹同步将暂停，避免其他设备的数据立即重新合并；检查无误后可手动重新启用。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认整库恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return (done: false, message: null);
    }
    onBusy?.call(true);
    final navigator = Navigator.of(context, rootNavigator: true);
    final progressRoute = RawDialogRoute<void>(
      transitionDuration: AppMotion.duration(context),
      barrierDismissible: false,
      barrierColor: Colors.black54,
      barrierLabel: '整库恢复进行中',
      pageBuilder: (_, _, _) => const PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text('正在恢复资料库'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TaskProgress(),
                SizedBox(height: 16),
                Text('请稍候，恢复完成前不要关闭应用。'),
              ],
            ),
          ),
        ),
      ),
    );
    final progress = navigator.push(progressRoute);
    final backupPath =
        '${state.backupDir}/恢复前备份-'
        '${DateTime.now().microsecondsSinceEpoch}-${newUuid()}.siq';
    try {
      await state.suspendSyncForRestore();
      final err = await state.writeInBackground(_restoreJob(plain, backupPath));
      if (err != null) return (done: true, message: '恢复失败：$err');
      state.store.clockSeen();
      return (done: true, message: '整库恢复完成；恢复前备份保存在 $backupPath。共享文件夹同步已暂停');
    } on Object catch (e) {
      return (done: true, message: '恢复失败：$e');
    } finally {
      if (progressRoute.isActive) navigator.removeRoute(progressRoute);
      await progress;
      onBusy?.call(false);
    }
  } finally {
    if (plain != path) File(plain).deleteSync();
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.title, required this.preview});
  final String title;
  final Map<String, TableImport> preview;

  @override
  Widget build(BuildContext context) {
    final changes = preview.values.fold(
      0,
      (n, t) => n + t.added + t.updated + t.merged,
    );
    final conflicts = preview.values.fold(0, (n, t) => n + t.conflicts.length);
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (changes == 0)
              const Text('这些内容本机都已有，无需导入。')
            else
              Table(
                columnWidths: const {0: FlexColumnWidth(2)},
                children: [
                  const TableRow(
                    children: [
                      Text('类别', style: TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        '新增',
                        textAlign: TextAlign.right,
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '更新',
                        textAlign: TextAlign.right,
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '无变化',
                        textAlign: TextAlign.right,
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  for (final e in preview.entries)
                    TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(_typeLabels[e.key] ?? e.key),
                        ),
                        for (final n in [
                          e.value.added,
                          e.value.updated,
                          e.value.ignored,
                        ])
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '$n',
                              textAlign: TextAlign.right,
                              style: const TextStyle(fontFeatures: tabular),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            if (conflicts > 0) ...[
              const SizedBox(height: 14),
              Text(
                '$conflicts 条记录在两台设备上都被修改过：改了不同地方的都会保留；改了同一处的采用较晚的修改，并列入待确认的冲突。',
                style: TextStyle(color: Tokens.amber),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: changes == 0 ? null : () => Navigator.pop(context, true),
          child: const Text('确认导入'),
        ),
      ],
    );
  }
}
