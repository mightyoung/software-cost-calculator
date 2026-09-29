import 'dart:convert';

import 'package:flutter/foundation.dart';
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
  const ListToProjectPage({super.key, required this.state, this.resumeJobId});
  final AppState state;
  final String? resumeJobId;

  @override
  State<ListToProjectPage> createState() => _ListToProjectPageState();
}

class _ListToProjectPageState extends State<ListToProjectPage> {
  final text = TextEditingController();
  String? fileName, error, progress;
  bool? hasKey;
  List<ProposedLine>? lines;
  var run = 0; // bumps on cancel so late replies are ignored
  AiCancellation? _cancellation;
  String? _jobId, fileText;
  Uint8List? fileBytes;
  Map<String, Object?>? _jobInput;
  String currency = 'CNY', taxMode = 'included';

  @override
  void initState() {
    super.initState();
    if (widget.resumeJobId case final id?) {
      try {
        final job = widget.state.aiTask(id);
        if (job.task == AiTask.listProposal) {
          _jobId = id;
          _jobInput = job.input;
          text.text = job.input['source'] as String;
          fileName = job.input['fileName'] as String?;
          final bytes = job.input['fileBytes'] as String?;
          fileBytes = bytes == null ? null : base64Decode(bytes);
          fileText = fileBytes == null ? null : text.text;
          currency = job.input['currency'] as String;
          taxMode = job.input['taxMode'] as String;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _start();
          });
        } else {
          error = '无法恢复这项清单任务';
        }
      } catch (e) {
        error = '任务读取失败：${friendlyError('$e')}';
      }
    }
    widget.state.hasAiKey().then((v) {
      if (mounted) setState(() => hasKey = v);
    });
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    text.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (progress != null) return;
    if (text.text.trim().isEmpty) {
      return setState(() => error = '先粘贴清单内容，或选择一个 Excel 文件');
    }
    final mine = ++run;
    final cancellation = _cancellation = AiCancellation();
    final source = text.text;
    final input = <String, Object?>{
      'source': source,
      'fileName': fileName,
      'fileBytes': fileBytes != null && source == fileText
          ? base64Encode(fileBytes!)
          : null,
      'currency': currency,
      'taxMode': taxMode,
    };
    final resumeId = mapEquals(input, _jobInput) ? _jobId : null;
    setState(() {
      error = null;
      progress = '正在整理清单…';
    });
    try {
      final result = await widget.state.runAiTask<List<ProposedLine>>(
        AiTask.listProposal,
        input,
        (llm) => widget.state.store.proposeFromList(
          llm,
          source,
          cancellation: cancellation,
          currency: input['currency']! as String,
          taxMode: input['taxMode']! as String,
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
        ),
        resumeId: resumeId,
        cancellation: cancellation,
        onCreated: (id) {
          _jobId = id;
          _jobInput = input;
        },
      );
      if (!mounted || mine != run) return;
      widget.state.validateAiTask(_jobId!);
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
          error = e.message;
        });
      }
    } catch (e) {
      if (mounted && mine == run) {
        setState(() {
          progress = null;
          error = friendlyError('$e');
        });
      }
    }
  }

  void _cancel() => setState(() {
    _cancellation?.cancel();
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
            aiTaskId: _jobId,
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
        'AI 会整理设备与材料并建议候选物料；匹配把握不代表技术符合，请核对参数。'
        '清单及候选物料的名称、型号和规格会发送给已配置的 AI 服务，价格仍在本机计算。确认前不会写入任何数据。',
    example:
        '例如：\n1. 不锈钢离心泵，Q=100m3/h，H=32m，2台\n2. 闸阀 DN100 PN16 ×4\n3. 动力电缆 YJV 4*25，约 300m',
    startLabel: '开始匹配',
    hasKey: hasKey,
    fileName: fileName,
    error: error,
    progress: progress,
    onFile: (name, bytes, err) => setState(() {
      fileName = name;
      fileBytes = err == null ? bytes : null;
      fileText = err == null ? text.text : null;
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
      onChanged: progress != null
          ? null
          : (v) => setState(() {
              currency = v!.split('|').first;
              taxMode = v.split('|').last;
            }),
    ),
  );
}
