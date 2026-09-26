import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import 'conflicts_page.dart';
import 'folder_sync_panel.dart';
import 'passphrase.dart';

const _typeLabels = {
  'supplier': '供应商',
  'contact': '联系人',
  'product': '物料',
  'project': '项目',
  'quotation': '报价',
  'project_item': '预算行',
};

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
      passphrase == null
          ? state.store.exportTo(file.path)
          : await state.store.exportEncryptedTo(file.path, passphrase);
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

  /// Decrypts an encrypted file with the stored passphrase, asking when
  /// there is none or it does not fit. Returns null when the user gives up.
  Future<String?> _plain(String path) async {
    if (!isEncryptedExchange(path)) return path;
    var passphrase = await state.exchangePassphrase();
    String? problem;
    while (true) {
      if (passphrase == null) {
        if (!mounted) return null;
        passphrase = await askPassphrase(
          context,
          title: '这个交换文件已加密',
          message: problem ?? '请输入对方设置的交换口令。',
        );
        if (passphrase == null) return null;
      }
      try {
        return await decryptExchange(path, passphrase, temp);
      } on FormatException {
        problem = '口令不对，或文件已损坏。请重新输入。';
        passphrase = null;
      }
    }
  }

  Future<void> _import() async {
    final picked = await pickToTemp(['siq'], temp);
    if (picked == null || !mounted) return;
    final path = await _plain(picked);
    if (path != picked) File(picked).deleteSync();
    if (path == null || !mounted) return;
    try {
      final Map<String, TableImport> preview;
      try {
        preview = state.store.previewImport(path);
      } on FormatException catch (e) {
        return toast(
          context,
          e.message.contains('newer version')
              ? '这个文件来自更新版本的程序，请先升级本机再导入'
              : '这不是有效的交换文件，或文件已损坏',
        );
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => _Preview(preview: preview),
      );
      if (confirmed != true || !mounted) return;
      setState(() => busy = true);
      final err = state.write((s) => s.importFrom(path));
      if (mounted) toast(context, err ?? '已合并交换文件');
    } finally {
      File(path).deleteSync();
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
        '生成本机全部数据的快照（.siq），发给其他设备导入即可同步。这个文件同时就是备份：新设备导入它即可恢复。',
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
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
      children: [
        Text('数据交换', style: Theme.of(context).textTheme.titleLarge),
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
        if (busy) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(),
        ],
        const SizedBox(height: 16),
        PassphraseRow(state: state),
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

class _Preview extends StatelessWidget {
  const _Preview({required this.preview});
  final Map<String, TableImport> preview;

  @override
  Widget build(BuildContext context) {
    final changes = preview.values.fold(
      0,
      (n, t) => n + t.added + t.updated + t.merged,
    );
    final conflicts = preview.values.fold(0, (n, t) => n + t.conflicts.length);
    return AlertDialog(
      title: const Text('导入预览'),
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (changes == 0)
              const Text('这个文件的内容本机都已有，无需导入。')
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
                style: const TextStyle(color: Tokens.amber),
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
