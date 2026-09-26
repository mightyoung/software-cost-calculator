import 'package:flutter/material.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import 'list_review.dart';
import 'source_input.dart';

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
          child: StepsBar(
            labels: const ['输入清单', '核对匹配', '生成项目'],
            current: lines == null ? 0 : 1,
          ),
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

  Widget _input(BuildContext context) => SourceInput(
    text: text,
    intro:
        '粘贴客户的建设清单或询价清单，格式不限（表格、编号列表或文字都可以），也可以直接选择 Excel 文件。'
        'AI 会整理出其中的设备与材料，并在物料库中找出最合适的物料。确认前不会写入任何数据。',
    example:
        '例如：\n1. 不锈钢离心泵，Q=100m3/h，H=32m，2台\n2. 闸阀 DN100 PN16 ×4\n3. 动力电缆 YJV 4*25，约 300m',
    startLabel: '开始匹配',
    hasKey: hasKey,
    fileName: fileName,
    error: error,
    progress: progress,
    onFile: (name, err) => setState(() {
      fileName = name;
      error = err;
    }),
    onStart: _start,
    onCancel: _cancel,
    extra: DropdownButton<String>(
      value: '$currency|$taxMode',
      underline: const SizedBox(),
      items: const [
        DropdownMenuItem(value: 'CNY|included', child: Text('参考报价：人民币 含税')),
        DropdownMenuItem(value: 'CNY|excluded', child: Text('参考报价：人民币 不含税')),
      ],
      onChanged: (v) => setState(() {
        currency = v!.split('|').first;
        taxMode = v.split('|').last;
      }),
    ),
  );
}
