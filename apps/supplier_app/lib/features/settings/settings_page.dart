import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../app/version.dart';
import '../../platform/files.dart';
import 'ai_settings.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.state});
  final AppState state;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final device = TextEditingController(text: widget.state.deviceName);

  @override
  void dispose() {
    device.dispose();
    super.dispose();
  }

  void _saveDevice() {
    final name = device.text.trim();
    if (name.isEmpty || name.length > 40) {
      return toast(context, '本机名称需要 1 到 40 个字');
    }
    widget.state.saveSetting('device_name', name);
    toast(context, '已保存，重新打开应用后生效');
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.state.store;
    int count(String type) =>
        store.db
                .select('SELECT count(*) AS n FROM $type WHERE deleted = 0')
                .first['n']
            as int;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
      children: [
        Text('设置', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 20),
        const Text('本机名称', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text(
          '用于交换文件名和变更记录，便于区分是哪台设备做的修改。',
          style: TextStyle(color: Tokens.ink2),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            SizedBox(
              width: 280,
              child: TextField(
                controller: device,
                onSubmitted: (_) => _saveDevice(),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _saveDevice, child: const Text('保存')),
          ],
        ),
        const SizedBox(height: 28),
        AiSettings(state: widget.state),
        const SizedBox(height: 28),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text(
            '诊断信息',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          children: [
            _kv('版本', appVersion),
            _kv('数据位置', widget.state.dataDir.path),
            _kv('自动备份', _backups()),
            for (final (type, label) in [
              ('project', '项目'),
              ('supplier', '供应商'),
              ('product', '物料'),
              ('quotation', '报价'),
              ('project_item', '预算行'),
            ])
              _kv(label, '${count(type)}'),
          ],
        ),
      ],
    );
  }

  /// Daily snapshots, newest seven kept. Full restore is separate from merge.
  String _backups() {
    final error = widget.state.backupError;
    if (error != null) return '今天的自动备份失败：$error';
    final dir = Directory(widget.state.backupDir);
    final files = dir.existsSync()
        ? (dir
              .listSync()
              .whereType<File>()
              .map((f) => f.uri.pathSegments.last)
              .where((n) => n.endsWith('.siq'))
              .toList()
            ..sort())
        : <String>[];
    if (files.isEmpty) return '还没有';
    return '文件：共 ${files.length} 份（每日自动备份保留最近 7 份；恢复前备份另外保存）\n'
        '位置：${dir.path}\n需要回到备份时，在“数据交换”选择“从备份恢复整个资料库”。';
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(k, style: const TextStyle(color: Tokens.ink3)),
        ),
        Expanded(child: SelectableText(v)),
      ],
    ),
  );
}
