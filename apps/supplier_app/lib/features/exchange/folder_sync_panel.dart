import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../app/version.dart';
import '../../platform/files.dart';

bool get folderSyncSupported =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

/// Sync through a folder all devices reach (network share, NAS, cloud-drive
/// folder), plus the update notice an administrator can put there.
class FolderSyncPanel extends StatefulWidget {
  const FolderSyncPanel({super.key, required this.state});
  final AppState state;

  @override
  State<FolderSyncPanel> createState() => _FolderSyncPanelState();
}

class _FolderSyncPanelState extends State<FolderSyncPanel> {
  var busy = false;
  AppState get state => widget.state;

  Future<void> _choose() async {
    final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择共享文件夹');
    if (dir == null) return;
    state.saveSetting('sync_dir', dir);
    state.saveSetting('sync_seen', null);
    await _sync();
  }

  Future<void> _sync() async {
    setState(() => busy = true);
    await Future<void>.delayed(Duration.zero); // let the spinner paint
    await state.syncNow();
    if (!mounted) return;
    setState(() => busy = false);
    final r = state.lastSync;
    toast(
      context,
      state.lastSyncError != null
          ? '同步失败：${state.lastSyncError}'
          : r == null
          ? '共享文件夹同步已暂停'
          : r.imported.isEmpty
          ? '已同步，其他设备没有新数据'
          : '已合并 ${r.imported.length} 台设备的数据',
    );
  }

  Future<void> _reveal(String dir) => Platform.isWindows
      ? Process.run('explorer', [dir])
      : Process.run('open', [dir]);

  @override
  Widget build(BuildContext context) {
    final dir = state.syncDir;
    final r = state.lastSync;
    final update = dir == null ? null : readUpdate(dir, current: appVersion);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Tokens.surface,
        border: Border.all(color: Tokens.rule),
        borderRadius: BorderRadius.circular(Tokens.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(Icons.folder_shared_outlined, color: Tokens.accent),
              const SizedBox(width: 10),
              Text('共享文件夹同步', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '选一个所有电脑都能访问的文件夹（公司共享盘、NAS 或网盘同步文件夹）。每台电脑只写自己的文件，并合并其他电脑的文件；打开软件时会自动同步一次。',
            style: TextStyle(color: Tokens.ink2, height: 1.6),
          ),
          const SizedBox(height: 12),
          if (dir == null)
            FilledButton(onPressed: _choose, child: const Text('选择共享文件夹'))
          else ...[
            SelectableText(dir, style: TextStyle(color: Tokens.ink2)),
            const SizedBox(height: 4),
            Text(
              '本机文件：${state.syncFileName}',
              style: TextStyle(fontSize: 12, color: Tokens.ink3),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: busy ? null : _sync,
                  child: Text(busy ? '正在同步…' : '立即同步'),
                ),
                OutlinedButton(
                  onPressed: busy ? null : _choose,
                  child: const Text('更换文件夹'),
                ),
                TextButton(
                  onPressed: () {
                    state.saveSetting('sync_dir', null);
                    state.saveSetting('sync_seen', null);
                  },
                  child: const Text('停止使用'),
                ),
              ],
            ),
            if (state.lastSyncError != null) ...[
              const SizedBox(height: 8),
              Text(
                '上次同步失败：${state.lastSyncError}',
                style: TextStyle(color: Tokens.red),
              ),
            ] else if (r != null) ...[
              const SizedBox(height: 8),
              Text(
                [
                  r.imported.isEmpty
                      ? '本次没有新数据'
                      : '本次合并了 ${r.imported.length} 台设备的数据',
                  if (r.failed.isNotEmpty)
                    '${r.failed.length} 个文件暂时读不了（可能还在上传），下次同步再试：'
                        '${r.failed.keys.join('、')}',
                ].join('；'),
                style: TextStyle(fontSize: 12, color: Tokens.ink2),
              ),
            ],
            if (update != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                decoration: BoxDecoration(
                  color: Tokens.accentTint,
                  borderRadius: BorderRadius.circular(Tokens.radius),
                ),
                child: Row(
                  children: [
                    AppIcon(Icons.system_update_alt, color: Tokens.accentDeep),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '有新版本 ${update.version}（本机 $appVersion）'
                        '${update.notes == null ? '' : '：${update.notes}'}'
                        '${update.file == null ? '' : '。安装包：${update.file}'}',
                      ),
                    ),
                    TextButton(
                      onPressed: () => _reveal(dir),
                      child: const Text('打开文件夹'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
