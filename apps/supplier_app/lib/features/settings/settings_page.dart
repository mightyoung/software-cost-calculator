import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';

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
    final file = File('${widget.state.dataDir.path}/settings.json');
    final settings =
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    settings['device_name'] = name;
    file.writeAsStringSync(jsonEncode(settings));
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
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text(
            '诊断信息',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          children: [
            _kv('数据位置', widget.state.dataDir.path),
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
