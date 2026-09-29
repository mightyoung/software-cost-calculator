import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';

/// Address and token of the optional company hub.
class HubSettings extends StatefulWidget {
  const HubSettings({super.key, required this.state});
  final AppState state;

  @override
  State<HubSettings> createState() => _HubSettingsState();
}

class _HubSettingsState extends State<HubSettings> {
  late final address = TextEditingController(
    text: widget.state.hubAddress ?? '',
  );
  final token = TextEditingController();
  bool hasToken = false, busy = false, statusOk = true;
  String? status;

  @override
  void initState() {
    super.initState();
    address.addListener(() => setState(() {}));
    widget.state.hasHubToken().then((v) {
      if (mounted) setState(() => hasToken = v);
    });
  }

  @override
  void dispose() {
    address.dispose();
    token.dispose();
    super.dispose();
  }

  Uri? get _typed {
    try {
      return address.text.trim().isEmpty ? null : parseHubAddress(address.text);
    } on FormatException {
      return null;
    }
  }

  void _say(String text, {bool ok = true}) => setState(() {
    status = text;
    statusOk = ok;
  });

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } on HubException catch (e) {
      _say(e.message, ok: false);
    } on FormatException catch (e) {
      _say(e.message, ok: false);
    } catch (e) {
      _say('无法写入系统安全存储：$e', ok: false);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _save() => _run(() async {
    final text = address.text.trim();
    final uri = text.isEmpty ? null : parseHubAddress(text);
    await widget.state.saveHub(
      address: uri?.toString(),
      token: token.text.trim().isEmpty ? null : token.text.trim(),
    );
    token.clear();
    final saved = await widget.state.hasHubToken();
    if (!mounted) return;
    setState(() => hasToken = saved);
    _say(uri == null ? '已关闭公司资料中心' : '已保存');
  });

  Future<void> _test() => _run(() async {
    final client = await widget.state.hub();
    if (client == null) throw HubException('请先填写并保存中心地址');
    _say('正在连接…');
    final s = await client.status();
    final store = (s['store'] as Map?) ?? const {};
    _say('连接正常：共享资料 ${store['publication_count'] ?? 0} 份');
  });

  Future<void> _clearToken() => _run(() async {
    await widget.state.saveHub(address: widget.state.hubAddress, token: '');
    if (!mounted) return;
    setState(() => hasToken = false);
    _say('已删除本机保存的访问令牌');
    toast(context, '已删除访问令牌');
  });

  @override
  Widget build(BuildContext context) {
    final uri = _typed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('公司资料中心', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          '可选。连接后可在"公司资料"里查同事共享的供应商和历史报价，'
          '也可以把选中的供应商或报价发布上去。不填写则本机完全独立工作。',
          style: TextStyle(color: Tokens.ink2),
        ),
        const SizedBox(height: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: address,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: '中心地址',
                  hintText: 'https://hub.example.com',
                ),
              ),
              if (uri != null && hubAddressIsPlainRemote(uri)) ...[
                const SizedBox(height: 6),
                const HintText(
                  '这是发往其他电脑的 http 地址，访问令牌和资料会以明文经过网络。'
                  '建议让管理员在中心前面配置 HTTPS。',
                  icon: Icons.error_outline,
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                controller: token,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: '访问令牌',
                  hintText: hasToken ? '已保存（不显示），留空表示不修改' : '由中心管理员提供；本机中心可不填',
                ),
                onSubmitted: (_) => _save(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton(
              onPressed: busy ? null : _save,
              child: const Text('保存'),
            ),
            OutlinedButton(
              onPressed: busy ? null : _test,
              child: const Text('测试连接'),
            ),
            if (hasToken)
              TextButton(
                onPressed: busy ? null : _clearToken,
                style: TextButton.styleFrom(foregroundColor: Tokens.red),
                child: const Text('删除访问令牌'),
              ),
            if (status != null)
              Text(
                status!,
                style: TextStyle(color: statusOk ? Tokens.ink2 : Tokens.red),
              ),
          ],
        ),
      ],
    );
  }
}
