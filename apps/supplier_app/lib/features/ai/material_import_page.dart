import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../app/app_state.dart';
import '../../app/theme.dart';
import 'material_review.dart';
import 'source_input.dart';

/// Opens the smart import flow; returns a summary line when something was
/// written.
Future<String?> showMaterialImport(
  BuildContext context,
  AppState state, {
  String? projectId,
  ({String name, Uint8List bytes, List<Offer> offers})? table,
  bool masterData = false,
}) => Navigator.of(context).push<String>(
  MaterialPageRoute(
    builder: (_) => MaterialImportPage(
      state: state,
      projectId: projectId,
      table: table,
      masterData: masterData,
    ),
  ),
);

class MaterialImportPage extends StatefulWidget {
  const MaterialImportPage({
    super.key,
    required this.state,
    this.projectId,
    this.table,
    this.masterData = false,
    this.resumeJobId,
  });
  final AppState state;
  final bool masterData;
  final String? projectId;
  final String? resumeJobId;

  /// A table already read without AI: opens straight at the review step.
  final ({String name, Uint8List bytes, List<Offer> offers})? table;

  @override
  State<MaterialImportPage> createState() => _MaterialImportPageState();
}

class _MaterialImportPageState extends State<MaterialImportPage> {
  final text = TextEditingController();
  String? fileName, fileText, error, progress;
  Uint8List? fileBytes;
  bool? hasKey;
  List<OfferPlan>? plans;
  var run = 0; // bumps on cancel so late replies are ignored
  AiCancellation? _cancellation;
  String? _jobId, _projectId;
  late bool _masterData;
  Map<String, Object?>? _jobInput;

  @override
  void initState() {
    super.initState();
    _projectId = widget.projectId;
    _masterData = widget.masterData;
    if (widget.resumeJobId case final id?) {
      try {
        final job = widget.state.aiTask(id);
        if (job.task == AiTask.offerExtraction) {
          _jobId = id;
          _jobInput = job.input;
          text.text = job.input['source'] as String;
          fileName = job.input['fileName'] as String?;
          final bytes = job.input['fileBytes'] as String?;
          fileBytes = bytes == null ? null : base64Decode(bytes);
          fileText = fileBytes == null ? null : text.text;
          _projectId = job.input['projectId'] as String?;
          _masterData = job.input['masterData'] == true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _start();
          });
        } else {
          error = '无法恢复这项导入任务';
        }
      } catch (e) {
        error = '任务读取失败：${friendlyError('$e')}';
      }
    }
    if (widget.table case final t?) {
      fileName = t.name;
      fileBytes = t.bytes;
      fileText = text.text;
      plans = [for (final o in t.offers) _plan(o)];
    }
    widget.state.hasAiKey().then((v) {
      if (mounted) setState(() => hasKey = v);
    });
  }

  /// A material list keeps only what describes the material.
  OfferPlan _plan(Offer o, {String? source}) => widget.state.store.planOffer(
    _masterData ? materialOffer(o) : o,
    source: source,
  );

  @override
  void dispose() {
    _cancellation?.cancel();
    text.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (progress != null) return;
    if (text.text.trim().isEmpty) {
      return setState(() => error = '先粘贴报价信息，或选择一个 Excel 文件');
    }
    // A table with a recognizable header is read column by column: exact,
    // instant and no AI key needed.
    try {
      final pasted = tableFromText(text.text);
      if ((fileBytes != null && text.text == fileText) || pasted != null) {
        final offers = offersFromWorkbook(
          fileBytes != null && text.text == fileText
              ? readXlsx(fileBytes!)
              : pasted!,
          materials: _masterData,
        );
        if (offers != null && offers.isNotEmpty) {
          return setState(() {
            error = null;
            _jobId = null;
            _jobInput = null;
            plans = [for (final o in offers) _plan(o)];
          });
        }
      }
    } on FormatException catch (e) {
      return setState(() => error = friendlyError(e.message));
    }
    final mine = ++run;
    final cancellation = _cancellation = AiCancellation();
    final source = text.text;
    final input = <String, Object?>{
      'source': source,
      'fileName': fileBytes != null && source == fileText ? fileName : null,
      'fileBytes': fileBytes != null && source == fileText
          ? base64Encode(fileBytes!)
          : null,
      'projectId': _projectId,
      'masterData': _masterData,
    };
    final resumeId = mapEquals(input, _jobInput) ? _jobId : null;
    setState(() {
      error = null;
      progress = '正在分析报价信息…';
    });
    try {
      final store = widget.state.store;
      final offers = await widget.state.runAiTask<List<Offer>>(
        AiTask.offerExtraction,
        input,
        (llm) => store.extractOffers(
          llm,
          source,
          cancellation: cancellation,
          onProgress: (done, total) {
            if (!mounted || mine != run || total < 2) return;
            setState(() => progress = '正在分析报价信息（第 ${done + 1}/$total 段）');
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
        if (offers.isEmpty) {
          error = '没有识别出产品报价，检查内容后重试。';
        } else {
          plans = [for (final o in offers) _plan(o, source: source)];
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: Tokens.canvas,
      title: Text(_masterData ? '导入物料清单' : '智能导入报价'),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(36),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: StepsBar(
            labels: const ['粘贴信息', '核对', '导入'],
            current: plans == null ? 0 : 1,
          ),
        ),
      ),
    ),
    body: plans != null
        ? MaterialReview(
            state: widget.state,
            plans: plans!,
            projectId: _projectId,
            masterData: _masterData,
            aiTaskId: _jobId,
            // Evidence kept on every new quotation: the original file when
            // one was chosen and not edited since, else the pasted text.
            source: fileBytes != null && text.text == fileText
                ? (name: fileName!, bytes: fileBytes!)
                : (
                    name: '报价信息-${localDay(DateTime.now())}.txt',
                    bytes: utf8.encode(text.text),
                  ),
            onBack: () => setState(() => plans = null),
          )
        : SourceInput(
            text: text,
            intro:
                '粘贴供应商发来的报价信息：微信聊天、邮件、报价单表格或文字都可以，也可以直接选择 Excel 文件。'
                '带表头的 Excel 文件或从 Excel 复制的多行（有"名称""品牌""型号""单价"等列）会直接按列读取，不需要 AI；其他内容由 '
                'AI 整理出供应商、联系人、产品、品牌型号、技术参数和价格，并与本机已有的供应商和物料对应。'
                '确认前不会写入任何数据。只会发送你粘贴的内容，不会发送本机数据。\n'
                'PDF 报价单可以直接复制其中的文字；截图可先用系统自带的文字识别复制出文字再粘贴'
                '（Windows 截图工具的"文本操作"、macOS 的实况文本、安卓的 Google 镜头）。',
            example:
                '例如：\n上海甲泵业 张经理 138xxxx0000\n格兰富 CR10-5 立式多级泵，10m³/h 扬程50m，'
                '含税单价 12500 元/台，交期 15 天，报价有效期至 10 月底',
            startLabel: '开始分析',
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
            onCancel: () => setState(() {
              _cancellation?.cancel();
              run++;
              progress = null;
            }),
          ),
  );
}
