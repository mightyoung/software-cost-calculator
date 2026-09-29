import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../app/version.dart';
import '../../platform/files.dart';
import '../hub/hub_settings.dart';
import 'ai_settings.dart';
import '../trash/trash_page.dart';

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
        Text(
          '用于交换文件名和变更记录，便于区分是哪台设备做的修改。',
          style: TextStyle(color: Tokens.ink2),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 280,
              child: TextField(
                controller: device,
                onSubmitted: (_) => _saveDevice(),
              ),
            ),
            OutlinedButton(onPressed: _saveDevice, child: const Text('保存')),
          ],
        ),
        const SizedBox(height: 28),
        const Text('外观', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'system', label: Text('跟随系统')),
              ButtonSegment(value: 'light', label: Text('浅色')),
              ButtonSegment(value: 'dark', label: Text('深色')),
            ],
            selected: {widget.state.setting('appearance') ?? 'system'},
            showSelectedIcon: false,
            onSelectionChanged: (v) => widget.state.saveSetting(
              'appearance',
              v.single == 'system' ? null : v.single,
            ),
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('减少动态效果'),
            subtitle: const Text('关闭页面位移和加载动画；系统的减少动态效果设置始终优先。'),
            value: widget.state.setting('reduce_motion') == 'true',
            onChanged: (value) => widget.state.saveSetting(
              'reduce_motion',
              value ? 'true' : null,
            ),
          ),
        ),
        const SizedBox(height: 28),
        AiSettings(state: widget.state),
        const SizedBox(height: 28),
        HubSettings(state: widget.state),
        const SizedBox(height: 28),
        const Text('已删除的记录', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(
          '删除的供应商、物料、项目、报价等保留在这里，可以恢复。',
          style: TextStyle(color: Tokens.ink2),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => showTrash(context, widget.state),
            icon: const AppIcon(Icons.restore_from_trash_outlined, size: 18),
            label: Text('查看（${store.deletedRecords().length} 条）'),
          ),
        ),
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
        '位置：${dir.path}\n需要回到备份时，在“同步与交换”选择“从备份恢复整个资料库”。';
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 96,
          child: Text(k, style: TextStyle(color: Tokens.ink3)),
        ),
        Expanded(child: SelectableText(v)),
      ],
    ),
  );
}
