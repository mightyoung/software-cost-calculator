import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import 'conflicts_page.dart';
import 'folder_sync_panel.dart';
import 'import_flow.dart';
import 'lan_panel.dart';
import 'passphrase.dart';

// Background jobs are built at top level so they capture only their
// arguments, never the page (which cannot be sent to another isolate).
Future<void> Function(Store) _exportJob(String out, String? passphrase) =>
    (s) async => passphrase == null
    ? s.exportTo(out)
    : await s.exportEncryptedTo(out, passphrase);

class ExchangePage extends StatefulWidget {
  const ExchangePage({super.key, required this.state});
  final AppState state;

  @override
  State<ExchangePage> createState() => _ExchangePageState();
}

class _ExchangePageState extends State<ExchangePage> {
  var busy = false;
  AppState get state => widget.state;
  Directory get temp => Directory('${state.dataDir.path}/tmp');

  Future<void> _export() async {
    setState(() => busy = true);
    try {
      await temp.create(recursive: true);
      final file = File('${temp.path}/export.siq');
      if (file.existsSync()) file.deleteSync();
      final passphrase = await state.exchangePassphrase();
      await state.store.inBackground(_exportJob(file.path, passphrase));
      final bytes = await file.readAsBytes();
      file.deleteSync();
      final saved = await saveBytes(
        '询价台账-${state.deviceName}-${today()}.siq',
        bytes,
        extensions: ['siq'],
      );
      if (saved && mounted) {
        toast(
          context,
          passphrase == null ? '交换文件已导出，可发送给其他设备' : '已导出加密的交换文件，对方需要设置同一个交换口令',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _import() async {
    final picked = await pickToTemp(['siq'], temp);
    if (picked == null || !mounted) return;
    try {
      final r = await reviewAndImport(
        context,
        state,
        picked,
        onBusy: (b) => setState(() => busy = b),
      );
      if (r.message != null && mounted) toast(context, r.message!);
    } finally {
      File(picked).deleteSync();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _restore() async {
    final picked = await pickToTemp(['siq'], temp);
    if (picked == null || !mounted) return;
    try {
      final r = await reviewAndRestore(
        context,
        state,
        picked,
        onBusy: (b) {
          if (mounted) setState(() => busy = b);
        },
      );
      if (r.message != null && mounted) toast(context, r.message!);
    } finally {
      File(picked).deleteSync();
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget panel(IconData icon, String title, String body, Widget action) =>
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Tokens.surface,
              border: Border.all(color: Tokens.rule),
              borderRadius: BorderRadius.circular(Tokens.radius),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: Tokens.accent),
                const SizedBox(height: 10),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: const TextStyle(color: Tokens.ink2, height: 1.6),
                ),
                const SizedBox(height: 16),
                action,
              ],
            ),
          ),
        );
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final panels = [
      panel(
        Icons.upload_file_outlined,
        '导出交换文件',
        '生成本机全部数据的快照（.siq），发给其他设备导入即可合并。也可留作备份，之后通过整库恢复回到这个时间点。',
        FilledButton(
          onPressed: busy ? null : _export,
          child: const Text('导出交换文件'),
        ),
      ),
      panel(
        Icons.download_outlined,
        '导入交换文件',
        '合并其他设备的交换文件。两台设备改了同一条记录的不同地方，都会保留；改了同一处的，采用较晚的修改并列入待确认的冲突。先导入哪个文件结果都一样；导入前会先显示将发生的变化。',
        OutlinedButton(
          onPressed: busy ? null : _import,
          child: const Text('选择交换文件'),
        ),
      ),
      panel(
        Icons.settings_backup_restore_outlined,
        '从备份恢复整个资料库',
        '将本机资料库完整替换为所选备份。适合回到旧状态；恢复前会自动另存本机资料库，并经过两次确认。',
        OutlinedButton(
          onPressed: busy ? null : _restore,
          child: const Text('选择备份并恢复'),
        ),
      ),
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
      children: [
        Text('同步与交换', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        if (wide)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [panels[0], const SizedBox(width: 16), panels[1]],
            ),
          )
        else ...[
          Row(children: [panels[0]]),
          const SizedBox(height: 12),
          Row(children: [panels[1]]),
        ],
        const SizedBox(height: 12),
        Row(children: [panels[2]]),
        if (busy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
        const SizedBox(height: 16),
        PassphraseRow(state: state),
        const SizedBox(height: 16),
        LanPanel(state: state),
        if (folderSyncSupported) ...[
          const SizedBox(height: 16),
          FolderSyncPanel(state: state),
        ],
        ListenableBuilder(
          listenable: state,
          builder: (context, _) {
            final n = state.store.openConflicts().length;
            if (n == 0) return const SizedBox();
            return Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                decoration: BoxDecoration(
                  color: Tokens.amberBg,
                  borderRadius: BorderRadius.circular(Tokens.radius),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.call_split, color: Tokens.amber),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '有 $n 处修改冲突需要确认',
                        style: const TextStyle(color: Tokens.amber),
                      ),
                    ),
                    TextButton(
                      onPressed: () => showConflicts(context, state),
                      child: const Text('去确认'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
