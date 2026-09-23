import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';

const _examples = [
  '离心水泵目前最低的有效报价是多少？来自哪个供应商？',
  '哪些项目的成本已经接近合同金额？',
  '甲泵业最近报过哪些价格？',
  '泵房改造工程还有哪些物料待询价？',
];

class _Message {
  _Message(this.fromUser, this.text, {this.error = false});
  final bool fromUser, error;
  final String text;
}

/// Questions about local data, answered through read-only tool calls.
class AskPage extends StatefulWidget {
  const AskPage({super.key, required this.state});
  final AppState state;

  @override
  State<AskPage> createState() => _AskPageState();
}

class _AskPageState extends State<AskPage> {
  final input = TextEditingController();
  final scroll = ScrollController();
  final messages = <_Message>[];
  var busy = false;

  @override
  void dispose() {
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _send([String? preset]) async {
    final question = (preset ?? input.text).trim();
    if (question.isEmpty || busy) return;
    input.clear();
    setState(() {
      messages.add(_Message(true, question));
      busy = true;
    });
    _scrollDown();
    _Message reply;
    try {
      final llm = await widget.state.llm();
      if (llm == null) {
        reply = _Message(
          false,
          '还没有配置 AI 服务。在 设置 › AI 接入 中填写 API Key 后再试。',
          error: true,
        );
      } else {
        final answer = await widget.state.store.ask(llm, question);
        reply = _Message(false, answer.isEmpty ? '没有得到回答，换个问法再试。' : answer);
      }
    } on LlmException catch (e) {
      reply = _Message(false, '连接 AI 服务失败：${e.message}。检查网络后重试。', error: true);
    }
    if (!mounted) return;
    setState(() {
      messages.add(reply);
      busy = false;
    });
    _scrollDown();
  }

  void _scrollDown() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (scroll.hasClients) {
      scroll.animateTo(
        scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 18, 24, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('问数据', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        const Text(
          'AI 只能查询本机数据，不会修改任何记录。回答中的金额来自数据库原值。',
          style: TextStyle(color: Tokens.ink2),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Tokens.surface,
              border: Border.all(color: Tokens.rule),
              borderRadius: BorderRadius.circular(Tokens.radius),
            ),
            child: messages.isEmpty
                ? _examplesView()
                : ListView.builder(
                    controller: scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: messages.length + (busy ? 1 : 0),
                    itemBuilder: (context, i) => i == messages.length
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                SizedBox(width: 10),
                                Text(
                                  '正在查询本机数据…',
                                  style: TextStyle(color: Tokens.ink3),
                                ),
                              ],
                            ),
                          )
                        : _bubble(messages[i]),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: input,
                enabled: !busy,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                decoration: const InputDecoration(hintText: '问一个关于报价、项目或物料的问题'),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: busy ? null : _send,
              child: const Text('发送'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _examplesView() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('可以这样问', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          for (final q in _examples)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => _send(q),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                  ),
                  child: Text(
                    q,
                    style: const TextStyle(fontWeight: FontWeight.w400),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _bubble(_Message m) => Align(
    alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 640),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: m.fromUser
            ? Tokens.accentTint
            : (m.error ? Tokens.redBg : Tokens.canvas),
        borderRadius: BorderRadius.circular(Tokens.radius),
      ),
      child: SelectableText(
        m.text,
        style: TextStyle(
          height: 1.6,
          color: m.error
              ? Tokens.red
              : (m.fromUser ? Tokens.accentDeep : Tokens.ink),
        ),
      ),
    ),
  );
}
