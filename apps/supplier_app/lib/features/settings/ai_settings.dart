import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';

class AiSettings extends StatefulWidget {
  const AiSettings({super.key, required this.state});
  final AppState state;

  @override
  State<AiSettings> createState() => _AiSettingsState();
}

class _AiSettingsState extends State<AiSettings> {
  late final base = TextEditingController(text: widget.state.aiBaseUrl);
  late final model = TextEditingController(text: widget.state.aiModel);
  final key = TextEditingController();
  bool hasKey = false, busy = false;
  String? status;
  bool statusOk = false;

  @override
  void initState() {
    super.initState();
    widget.state.hasAiKey().then((v) {
      if (mounted) setState(() => hasKey = v);
    });
  }

  @override
  void dispose() {
    for (final c in [base, model, key]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final url = base.text.trim().replaceFirst(RegExp(r'/+$'), '');
    if (!url.startsWith('https://')) {
      return setState(() {
        status = '服务地址需要以 https:// 开头';
        statusOk = false;
      });
    }
    if (model.text.trim().isEmpty) {
      return setState(() {
        status = '请填写模型名称';
        statusOk = false;
      });
    }
    try {
      await widget.state.saveAi(
        baseUrl: url,
        model: model.text.trim(),
        apiKey: key.text.trim().isEmpty ? null : key.text.trim(),
      );
    } catch (e) {
      return setState(() {
        status = '无法写入系统安全存储：$e';
        statusOk = false;
      });
    }
    key.clear();
    hasKey = await widget.state.hasAiKey();
    if (mounted) {
      setState(() {
        status = '已保存';
        statusOk = true;
      });
    }
  }

  Future<void> _test() async {
    setState(() {
      busy = true;
      status = '正在连接…';
      statusOk = true;
    });
    try {
      final llm = await widget.state.llm();
      if (llm == null) throw LlmException('还没有保存 API Key');
      final reply = await llm.json('只输出 json。', '请原样返回这个 json：{"ok": true}');
      if (reply['ok'] != true) throw LlmException('模型回复内容异常');
      setState(() {
        status = '连接正常：${widget.state.aiModel}';
        statusOk = true;
      });
    } on LlmException catch (e) {
      setState(() {
        status = '连接失败：${e.message}';
        statusOk = false;
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _clearKey() async {
    await widget.state.saveAi(
      baseUrl: widget.state.aiBaseUrl,
      model: widget.state.aiModel,
      apiKey: '',
    );
    setState(() {
      hasKey = false;
      status = '已删除本机保存的 API Key';
      statusOk = true;
    });
    if (mounted) toast(context, '已删除 API Key');
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('AI 接入', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      Text(
        '用于"按清单建项目"、"智能导入报价"和"问数据"。默认使用 DeepSeek，也可以填写其他兼容 OpenAI 接口的服务。',
        style: TextStyle(color: Tokens.ink2),
      ),
      const SizedBox(height: 12),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          children: [
            TextField(
              controller: base,
              decoration: const InputDecoration(labelText: '服务地址'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: model,
              decoration: const InputDecoration(
                labelText: '模型名称',
                hintText: 'deepseek-flash 或 deepseek-v4-pro',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: hasKey ? '已保存（不显示），留空表示不修改' : 'sk-…',
              ),
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
      ),
      const SizedBox(height: 4),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: widget.state.specAi,
          onChanged: (v) => setState(() => widget.state.specAi = v),
          title: const Text('技术要求使用 AI 解析'),
          subtitle: const Text(
            '规则读不准的条款交给 AI 再读一遍。只发送条款原文和参数清单，不发送本机数据；'
            '技术要求涉密时请保持关闭，或把服务地址改成本机部署的模型。',
          ),
        ),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton(onPressed: busy ? null : _save, child: const Text('保存')),
          OutlinedButton(
            onPressed: busy ? null : _test,
            child: const Text('测试连接'),
          ),
          if (hasKey)
            TextButton(
              onPressed: busy ? null : _clearKey,
              style: TextButton.styleFrom(foregroundColor: Tokens.red),
              child: const Text('删除 API Key'),
            ),
          if (status != null)
            Text(
              status!,
              style: TextStyle(color: statusOk ? Tokens.ink2 : Tokens.red),
            ),
        ],
      ),
      const SizedBox(height: 12),
      Container(
        constraints: const BoxConstraints(maxWidth: 560),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Tokens.sunken,
          borderRadius: BorderRadius.circular(Tokens.radius),
        ),
        child: Text(
          '会发送给 AI 服务的内容：\n'
          '· 按清单建项目：你提供的清单文本，以及候选物料的名称、品牌、型号、规格和单位（不含价格和供应商）。\n'
          '· 智能导入报价：只发送你粘贴的报价信息，不发送本机数据；与已有供应商和物料的对应在本机完成。\n'
          '· 问数据：你的问题，以及为回答问题查到的记录（可能包含价格和供应商）。\n'
          '· 技术要求（打开上面的开关后）：规则读不准的条款原文和该类别的参数清单，不含本机物料和价格。\n'
          'API Key 只保存在本机的系统安全存储中，不会写入数据库，也不会随交换文件传到其他设备。',
          style: TextStyle(fontSize: 12, color: Tokens.ink2, height: 1.6),
        ),
      ),
    ],
  );
}
