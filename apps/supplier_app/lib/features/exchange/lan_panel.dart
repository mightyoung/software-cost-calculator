import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';
import 'import_flow.dart';
import 'lan_push_page.dart';

/// Local-network sharing on the exchange page: visibility switch, nearby
/// devices, and pushes waiting to be accepted.
class LanPanel extends StatefulWidget {
  const LanPanel({super.key, required this.state});
  final AppState state;

  @override
  State<LanPanel> createState() => _LanPanelState();
}

class _LanPanelState extends State<LanPanel> {
  var busy = false;
  AppState get state => widget.state;
  late final _addresses = _ownAddresses();
  late final _hasPassphrase = state.exchangePassphrase().then((p) => p != null);

  static Future<List<String>> _ownAddresses() async {
    try {
      return [
        for (final i in await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        ))
          for (final a in i.addresses) a.address,
      ];
    } on SocketException {
      return [];
    }
  }

  Future<void> _toggle(bool on) async {
    setState(() => busy = true);
    await state.setLanVisible(on);
    if (mounted) setState(() => busy = false);
  }

  Future<void> _addByAddress() async {
    final host = await showAppDialog<String>(
      context: context,
      builder: (_) => const _AddressDialog(),
    );
    if (host == null || state.lan == null) return;
    try {
      final peer = await state.lan!.probe(host);
      if (mounted) toast(context, '已找到 ${peer.name}');
    } on LanException catch (e) {
      if (mounted) toast(context, e.message);
    }
  }

  Future<void> _open(LanPush push) async {
    final r = await reviewAndImport(
      context,
      state,
      push.path,
      title: '来自 ${push.fromName} 的推送',
      onBusy: (b) {
        if (mounted) setState(() => busy = b);
      },
    );
    if (r.done) state.dismissPush(push);
    if (r.message != null && mounted) toast(context, r.message!);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) {
      final node = state.lan;
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
                AppIcon(Icons.wifi_tethering, color: Tokens.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '局域网互传',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                Text('局域网可见', style: TextStyle(color: Tokens.ink2)),
                const SizedBox(width: 6),
                Switch(
                  value: state.lanVisible,
                  onChanged: busy ? null : _toggle,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '同一 Wi-Fi 或办公网里、都打开了"局域网可见"的设备会互相看到。选中项目、物料或供应商推送过去，关联的预算行、报价、联系人会一起带上；对方确认后才会导入，合并方式和交换文件相同。',
              style: TextStyle(color: Tokens.ink2, height: 1.6),
            ),
            if (state.lanError != null) ...[
              const SizedBox(height: 8),
              Text(state.lanError!, style: TextStyle(color: Tokens.red)),
            ],
            if (node != null) ...[
              FutureBuilder(
                future: _hasPassphrase,
                builder: (_, s) => s.data == false
                    ? const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: HintText(
                          '还没有设置交换口令：推送内容在局域网中不加密。建议在上方设置交换口令，所有设备用同一个。',
                          icon: Icons.lock_open,
                        ),
                      )
                    : const SizedBox(),
              ),
              const SizedBox(height: 14),
              ..._incoming(),
              const Text(
                '附近的设备',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              if (node.peers.isEmpty)
                Text(
                  '正在查找…对方也需要打开"局域网可见"。找不到时可按地址添加。',
                  style: TextStyle(color: Tokens.ink3),
                )
              else
                for (final p in node.peers)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        AppIcon(Icons.computer, size: 18, color: Tokens.ink2),
                        const SizedBox(width: 8),
                        Text(p.name),
                        const SizedBox(width: 8),
                        Text(
                          p.address,
                          style: TextStyle(fontSize: 12, color: Tokens.ink3),
                        ),
                      ],
                    ),
                  ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: busy ? null : () => showLanPush(context, state),
                    icon: const AppIcon(Icons.send_outlined, size: 18),
                    label: const Text('选择内容推送'),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : _addByAddress,
                    child: const Text('按地址添加设备'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              FutureBuilder(
                future: _addresses,
                builder: (_, s) => Text(
                  s.data == null || s.data!.isEmpty
                      ? ''
                      : '本机地址：${s.data!.join('、')}',
                  style: TextStyle(fontSize: 12, color: Tokens.ink3),
                ),
              ),
            ],
            if (busy) ...[const SizedBox(height: 10), const TaskProgress()],
          ],
        ),
      );
    },
  );

  List<Widget> _incoming() => [
    if (state.incoming.isNotEmpty) ...[
      const Text('收到的推送', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      for (final p in state.incoming)
        Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          decoration: BoxDecoration(
            color: Tokens.accentTint,
            borderRadius: BorderRadius.circular(Tokens.radius),
          ),
          child: Row(
            children: [
              AppIcon(Icons.move_to_inbox, color: Tokens.accentDeep),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '来自 ${p.fromName}（${p.address}）· '
                  '${p.at.hour.toString().padLeft(2, '0')}:'
                  '${p.at.minute.toString().padLeft(2, '0')}',
                ),
              ),
              TextButton(
                onPressed: busy ? null : () => _open(p),
                child: const Text('查看并导入'),
              ),
              TextButton(
                onPressed: busy ? null : () => state.dismissPush(p),
                child: const Text('忽略'),
              ),
            ],
          ),
        ),
      const SizedBox(height: 10),
    ],
  ];
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog();

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  final text = TextEditingController();
  String? error;

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  void _ok() {
    final v = text.text.trim();
    if (InternetAddress.tryParse(v)?.type != InternetAddressType.IPv4) {
      return setState(() => error = '请输入对方的 IPv4 地址，例如 192.168.1.23');
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('按地址添加设备'),
    content: SizedBox(
      width: 360,
      child: TextField(
        controller: text,
        autofocus: true,
        decoration: InputDecoration(
          labelText: '对方地址',
          hintText: '在对方的"局域网互传"里可以看到本机地址',
          errorText: error,
        ),
        onSubmitted: (_) => _ok(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _ok, child: const Text('添加')),
    ],
  );
}
