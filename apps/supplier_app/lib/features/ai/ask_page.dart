import 'dart:convert';

import 'package:flutter/material.dart';

import '../../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../records/open_record.dart';

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

  /// What the assistant is doing right now (the tool it called last).
  String? activity;

  /// Earlier questions and answers stay on this device (last 100 messages),
  /// so leaving the page or restarting keeps them.
  static const _historyKey = 'ask_history';

  @override
  void initState() {
    super.initState();
    try {
      final saved = jsonDecode(widget.state.setting(_historyKey) ?? '[]');
      for (final m in (saved as List).whereType<List>()) {
        messages.add(_Message(m[0] == true, '${m[1]}', error: m[2] == true));
      }
    } on FormatException {
      // A damaged history is simply dropped.
    }
    if (messages.isNotEmpty) _scrollDown(animate: false);
  }

  void _saveHistory() => widget.state.saveSetting(
    _historyKey,
    jsonEncode([
      for (final m in messages.skip(
        messages.length > 100 ? messages.length - 100 : 0,
      ))
        [m.fromUser, m.text, m.error],
    ]),
  );

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
      activity = null;
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
        final answer = await widget.state.store.ask(
          llm,
          question,
          onTool: (tool) {
            if (mounted) setState(() => activity = toolActivity[tool]);
          },
        );
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
    _saveHistory();
    _scrollDown();
  }

  void _scrollDown({bool animate = true}) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scroll.hasClients && !animate) {
          scroll.jumpTo(scroll.position.maxScrollExtent);
        } else if (scroll.hasClients) {
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
        Row(
          children: [
            Expanded(
              child: Text('问数据', style: Theme.of(context).textTheme.titleLarge),
            ),
            if (messages.isNotEmpty && !busy)
              TextButton.icon(
                onPressed: () {
                  setState(messages.clear);
                  widget.state.saveSetting(_historyKey, null);
                },
                icon: const AppIcon(Icons.delete_sweep_outlined, size: 18),
                label: const Text('清空记录'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'AI 只能查询本机数据，不会修改任何记录。回答中的金额来自数据库原值。问答记录只保存在本机。',
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
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              children: [
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: TaskProgress(
                                    compact: true,
                                    strokeWidth: 2,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  activity == null ? '正在理解问题…' : '正在$activity…',
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
      child: Text.rich(
        TextSpan(
          children: m.fromUser || m.error
              ? [TextSpan(text: m.text)]
              : _answerSpans(m.text),
        ),
        style: TextStyle(
          height: 1.6,
          color: m.error
              ? Tokens.red
              : (m.fromUser ? Tokens.accentDeep : Tokens.ink),
        ),
      ),
    ),
  );

  /// Answer text with each `[[type:id|name]]` shown as a record chip that
  /// opens the record; stray ids the model still wrote are dropped.
  List<InlineSpan> _answerSpans(String text) {
    final spans = <InlineSpan>[];
    var at = 0;
    final clean = tidyAnswer(text);
    for (final m in recordRef.allMatches(clean)) {
      spans.add(TextSpan(text: clean.substring(at, m.start)));
      final (type, id, name) = (m[1]!, m[2]!, m[3]!);
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _RecordChip(
            name: name,
            onTap: () => openRecord(context, widget.state, type, id),
          ),
        ),
      );
      at = m.end;
    }
    spans.add(TextSpan(text: clean.substring(at)));
    return spans;
  }
}

final _uuid = RegExp(
  r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
);

/// Drops ids written outside record marks: "（ID 1f…）", "id：`1f…`".
String tidyAnswer(String text) {
  final marks = <String>[];
  final protected = text.replaceAllMapped(recordRef, (m) {
    marks.add(m[0]!);
    return '\u0000${marks.length - 1}\u0000';
  });
  final stripped = protected
      .replaceAll(
        RegExp(
          r'\s*[（(][^（()）]*?(?:ID|id|编号)[：:\s]*`?'
          '${_uuid.pattern}'
          r'`?[^（()）]*?[）)]',
        ),
        '',
      )
      .replaceAll(
        RegExp(
          r'[，,;；]?\s*(?:ID|id)[：:\s]*`?'
          '${_uuid.pattern}'
          r'`?',
        ),
        '',
      )
      .replaceAll(RegExp('`?${_uuid.pattern}`?'), '');
  return stripped.replaceAllMapped(
    RegExp('\u0000(\\d+)\u0000'),
    (m) => marks[int.parse(m[1]!)],
  );
}

class _RecordChip extends StatelessWidget {
  const _RecordChip({required this.name, required this.onTap});
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: Material(
      color: Tokens.accentTint,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Text(
            name,
            style: TextStyle(
              color: Tokens.accentDeep,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ),
  );
}
