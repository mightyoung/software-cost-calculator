import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../../widgets/ledger.dart';
import 'list_review.dart';

/// Opens the three-step flow; returns the new project id when created.
Future<String?> showListToProject(BuildContext context, AppState state) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => ListToProjectPage(state: state)),
    );

class ListToProjectPage extends StatefulWidget {
  const ListToProjectPage({super.key, required this.state});
  final AppState state;

  @override
  State<ListToProjectPage> createState() => _ListToProjectPageState();
}

class _ListToProjectPageState extends State<ListToProjectPage> {
  final text = TextEditingController();
  String? fileName, error, progress;
  bool? hasKey;
  List<ProposedLine>? lines;
  var run = 0; // bumps on cancel so late replies are ignored
  String currency = 'CNY', taxMode = 'included';

  @override
  void initState() {
    super.initState();
    widget.state.hasAiKey().then((v) {
      if (mounted) setState(() => hasKey = v);
    });
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> _pickExcel() async {
    final file = await pickBytes(['xlsx']);
    if (file == null) return;
    try {
      text.text = workbookText(readXlsx(file.bytes));
      setState(() {
        fileName = file.name;
        error = null;
      });
    } on FormatException catch (e) {
      setState(() => error = '无法读取 ${file.name}：${e.message}');
    }
  }

  Future<void> _start() async {
    if (text.text.trim().isEmpty) {
      return setState(() => error = '先粘贴清单内容，或选择一个 Excel 文件');
    }
    final llm = await widget.state.llm();
    if (llm == null) {
      return setState(
        () => error = '还没有配置 AI 服务。在 设置 › AI 接入 中填写 API Key 后再试。',
      );
    }
    final mine = ++run;
    setState(() {
      error = null;
      progress = '正在整理清单…';
    });
    try {
      final result = await widget.state.store.proposeFromList(
        llm,
        text.text,
        currency: currency,
        taxMode: taxMode,
        onProgress: (stage, done, total) {
          if (!mounted || mine != run) return;
          setState(
            () => progress = switch (stage) {
              ListStage.structuring =>
                total > 1 ? '正在整理清单（第 ${done + 1}/$total 段）' : '正在整理清单…',
              ListStage.matching => '正在匹配物料（$done/$total）',
            },
          );
        },
      );
      if (!mounted || mine != run) return;
      setState(() {
        progress = null;
        if (result.isEmpty) {
          error = '没有从清单中识别出需要采购的设备或材料，检查清单内容后重试。';
        } else {
          lines = result;
        }
      });
    } on LlmException catch (e) {
      if (mounted && mine == run) {
        setState(() {
          progress = null;
          error = '连接 AI 服务失败：${e.message}。检查网络和 API Key 后重试。';
        });
      }
    }
  }

  void _cancel() => setState(() {
    run++;
    progress = null;
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: Tokens.canvas,
      title: const Text('按清单建项目'),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(36),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: _Steps(current: lines == null ? 0 : 1),
        ),
      ),
    ),
    body: lines != null
        ? ListReview(
            state: widget.state,
            source: text.text,
            sourceName: fileName,
            lines: lines!,
            currency: currency,
            taxMode: taxMode,
            onBack: () => setState(() => lines = null),
          )
        : _input(context),
  );

  Widget _input(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '粘贴客户的建设清单或询价清单，格式不限（表格、编号列表或文字都可以），也可以直接选择 Excel 文件。'
          'AI 会整理出其中的设备与材料，并在物料库中找出最合适的物料。确认前不会写入任何数据。',
          style: TextStyle(color: Tokens.ink2, height: 1.6),
        ),
        if (hasKey == false) ...[
          const SizedBox(height: 10),
          const HintText(
            '还没有配置 AI 服务：在 设置 › AI 接入 中填写 API Key。',
            icon: Icons.info_outline,
          ),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: progress == null ? _pickExcel : null,
              icon: const Icon(Icons.table_view_outlined, size: 18),
              label: const Text('选择 Excel 文件'),
            ),
            if (fileName != null)
              Text('已读取：$fileName', style: const TextStyle(color: Tokens.ink2)),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: '$currency|$taxMode',
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(
                  value: 'CNY|included',
                  child: Text('参考报价：人民币 含税'),
                ),
                DropdownMenuItem(
                  value: 'CNY|excluded',
                  child: Text('参考报价：人民币 不含税'),
                ),
              ],
              onChanged: (v) => setState(() {
                currency = v!.split('|').first;
                taxMode = v.split('|').last;
              }),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: TextField(
            controller: text,
            expands: true,
            maxLines: null,
            textAlignVertical: TextAlignVertical.top,
            enabled: progress == null,
            decoration: const InputDecoration(
              hintText:
                  '例如：\n1. 不锈钢离心泵，Q=100m3/h，H=32m，2台\n2. 闸阀 DN100 PN16 ×4\n3. 动力电缆 YJV 4*25，约 300m',
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (error != null) ...[
          Text(error!, style: const TextStyle(color: Tokens.red)),
          const SizedBox(height: 8),
        ],
        if (progress != null) ...[
          Text(progress!, style: const TextStyle(color: Tokens.ink2)),
          const SizedBox(height: 6),
          const LinearProgressIndicator(),
          const SizedBox(height: 10),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (progress != null)
              OutlinedButton(onPressed: _cancel, child: const Text('取消'))
            else
              FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.arrow_forward, size: 18),
                label: const Text('开始匹配'),
              ),
          ],
        ),
      ],
    ),
  );
}

class _Steps extends StatelessWidget {
  const _Steps({required this.current});
  final int current;

  @override
  Widget build(BuildContext context) {
    Widget step(int i, String label) {
      final done = i < current, on = i == current;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? Tokens.accent : Colors.transparent,
              border: Border.all(
                color: done
                    ? Tokens.accent
                    : (on ? Tokens.ink : Tokens.ruleStrong),
              ),
            ),
            child: done
                ? const Icon(Icons.check, size: 13, color: Colors.white)
                : Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: 11,
                      color: on ? Tokens.ink : Tokens.ink3,
                    ),
                  ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: on ? Tokens.ink : Tokens.ink3,
              fontWeight: on ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      );
    }

    Widget line() => Container(
      width: 28,
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: Tokens.ruleStrong,
    );
    return Row(
      children: [
        step(0, '输入清单'),
        line(),
        step(1, '核对匹配'),
        line(),
        step(2, '生成项目'),
      ],
    );
  }
}
