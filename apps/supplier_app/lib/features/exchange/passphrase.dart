import 'package:flutter/material.dart';

import '../../app/motion.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/theme.dart';

/// Asks for a passphrase. [confirm] adds a repeat field (when setting one).
Future<String?> askPassphrase(
  BuildContext context, {
  required String title,
  String? message,
  bool confirm = false,
}) => showAppDialog<String>(
  context: context,
  builder: (_) =>
      _PassphraseDialog(title: title, message: message, confirm: confirm),
);

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({
    required this.title,
    required this.confirm,
    this.message,
  });
  final String title;
  final String? message;
  final bool confirm;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final a = TextEditingController(), b = TextEditingController();
  String? error;

  @override
  void dispose() {
    a.dispose();
    b.dispose();
    super.dispose();
  }

  void _ok() {
    if (widget.confirm && a.text.length < 8) {
      return setState(() => error = '口令至少 8 位');
    }
    if (widget.confirm && a.text != b.text) {
      return setState(() => error = '两次输入不一致');
    }
    if (a.text.isEmpty) return setState(() => error = '请输入口令');
    Navigator.pop(context, a.text);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.message != null) ...[
            Text(widget.message!, style: TextStyle(color: Tokens.ink2)),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: a,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: '口令'),
            onSubmitted: (_) => widget.confirm ? null : _ok(),
          ),
          if (widget.confirm) ...[
            const SizedBox(height: 10),
            TextField(
              controller: b,
              obscureText: true,
              decoration: const InputDecoration(labelText: '再输入一次'),
              onSubmitted: (_) => _ok(),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 10),
            Text(error!, style: TextStyle(color: Tokens.red)),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _ok, child: const Text('确定')),
    ],
  );
}

/// "交换口令" row: set, change or clear the team's exchange passphrase.
class PassphraseRow extends StatefulWidget {
  const PassphraseRow({super.key, required this.state});
  final AppState state;

  @override
  State<PassphraseRow> createState() => _PassphraseRowState();
}

class _PassphraseRowState extends State<PassphraseRow> {
  bool? isSet;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await widget.state.exchangePassphrase();
    if (mounted) setState(() => isSet = v != null);
  }

  Future<void> _set() async {
    final v = await askPassphrase(
      context,
      title: isSet == true ? '更改交换口令' : '设置交换口令',
      message: '所有设备要设置同一个口令。口令只保存在本机的系统安全存储里，忘记后无法找回，但可以重新设置。',
      confirm: true,
    );
    if (v == null) return;
    await widget.state.saveExchangePassphrase(v);
    await _load();
  }

  Future<void> _clear() async {
    await widget.state.saveExchangePassphrase(null);
    await _load();
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
    decoration: BoxDecoration(
      color: Tokens.surface,
      border: Border.all(color: Tokens.rule),
      borderRadius: BorderRadius.circular(Tokens.radius),
    ),
    child: Row(
      children: [
        AppIcon(
          isSet == true ? Icons.lock_outline : Icons.lock_open_outlined,
          color: isSet == true ? Tokens.accent : Tokens.ink3,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isSet == true ? '交换口令：已设置' : '交换口令：未设置',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                '设置后，导出的交换文件和共享文件夹里本机的文件都会加密（AES-256）；导入加密文件时使用这个口令。',
                style: TextStyle(fontSize: 12, color: Tokens.ink2),
              ),
            ],
          ),
        ),
        TextButton(onPressed: _set, child: Text(isSet == true ? '更改' : '设置口令')),
        if (isSet == true)
          TextButton(onPressed: _clear, child: const Text('清除')),
      ],
    ),
  );
}
