import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../app/motion.dart';
import 'package:supplier_core/supplier_core.dart';

import '../../widgets/app_icon.dart';
import '../../app/app_state.dart';
import '../../app/shell.dart';
import '../../app/theme.dart';
import '../../platform/files.dart';
import '../records/open_record.dart';
import 'assistant_confirmation.dart';

const _examples = [
  '离心水泵目前最低的有效报价是多少？来自哪个供应商？',
  '哪些项目的成本已经接近合同金额？',
  '甲泵业最近报过哪些价格？',
  '泵房改造工程还有哪些物料待询价？',
];

class _Message {
  _Message(
    this.fromUser,
    this.text, {
    this.error = false,
    this.evidence,
    this.appliedActions = const [],
  });
  final bool fromUser, error;
  final String text;
  // Evidence belongs only to this page session, never to saved history.
  final AssistantAnswer? evidence;
  final List<Map<String, Object?>> appliedActions;
}

/// Local queries, optional web research and individually approved app actions.
class AskPage extends StatefulWidget {
  const AskPage({
    super.key,
    required this.state,
    this.resumeJobId,
    this.onOpenPage,
  });
  final AppState state;
  final String? resumeJobId;
  final void Function(String page)? onOpenPage;

  @override
  State<AskPage> createState() => _AskPageState();
}

class _AskPageState extends State<AskPage> {
  final input = TextEditingController();
  final scroll = ScrollController();
  final messages = <_Message>[];
  var busy = false;
  AssistantCancellation? _cancellation;
  // Local history stays local unless the user opts in for this page session.
  var _includeHistory = false;

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
      if (saved is List) {
        for (final m in saved.skip(
          saved.length > 100 ? saved.length - 100 : 0,
        )) {
          if (m is List &&
              m.length == 3 &&
              m[0] is bool &&
              m[1] is String &&
              m[2] is bool) {
            messages.add(
              _Message(m[0] as bool, m[1] as String, error: m[2] as bool),
            );
          }
        }
      }
    } on FormatException {
      // A damaged history is simply dropped.
    }
    if (messages.isNotEmpty) _scrollDown(animate: false);
    if (widget.resumeJobId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resume();
      });
    }
  }

  void _resume() {
    try {
      final job = widget.state.aiTask(widget.resumeJobId!);
      final history = [
        for (final pair in job.input['history'] as List)
          AssistantTurn(pair[0] as String, pair[1] as String),
      ];
      _send(job.input['question'] as String, history, job.id);
    } catch (_) {
      setState(
        () => messages.add(_Message(false, '任务无法恢复，请从任务列表重新开始。', error: true)),
      );
    }
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

  void _trimMessages() {
    if (messages.length > 100) {
      // Drop whole question/answer pairs, including while a reply is pending.
      final excess = messages.length - 100;
      messages.removeRange(0, excess.isEven ? excess : excess + 1);
    }
    var retained = 0;
    for (var i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      if (message.evidence != null && ++retained > 6) {
        messages[i] = _Message(
          message.fromUser,
          message.text,
          error: message.error,
        );
      }
    }
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _send([
    String? preset,
    List<AssistantTurn>? resumedHistory,
    String? resumeId,
  ]) async {
    final question = (preset ?? input.text).trim();
    if (question.isEmpty || busy) return;
    final history = resumedHistory ?? <AssistantTurn>[];
    if (resumedHistory == null && _includeHistory) {
      for (var i = 1; i < messages.length; i++) {
        final question = messages[i - 1], answer = messages[i];
        if (question.fromUser &&
            !question.error &&
            !answer.fromUser &&
            !answer.error) {
          history.add(AssistantTurn(question.text, answer.text));
        }
      }
    }
    final cancellation = _cancellation = AssistantCancellation();
    input.clear();
    setState(() {
      messages.add(_Message(true, question));
      _trimMessages();
      busy = true;
      activity = null;
    });
    _scrollDown(force: true);
    _Message reply;
    String? jobId;
    AssistantAppTools? appTools;
    AssistantProcurementTools? procurement;
    AssistantWebTools? web;
    final completed = <AssistantObservation>[];
    Map<String, String>? navigation;
    final permission = widget.state.assistantPermission;
    final webEnabled = widget.state.assistantWebEnabled;
    try {
      final answer = await widget.state.runAiTask(
        AiTask.conversation,
        {
          'question': question,
          'history': [
            for (final t in history) [t.question, t.answer],
          ],
        },
        (llm) async {
          final raw = await widget.state.store.askWithEvidence(
            llm,
            question,
            history: history,
            cancellation: cancellation,
            toolsets: [
              appTools!,
              procurement!,
              if (webEnabled)
                _ReviewedWebTools(
                  (name, args, cancel) =>
                      confirmAssistantNetwork(context, name, args, cancel),
                  () => widget.state.assistantWebEnabled,
                  web!,
                ),
              _AppNavigationTools(
                widget.state.store,
                (request) => navigation = request,
              ),
            ],
            onObservation: completed.add,
            onCompact: () {
              if (mounted) setState(() => activity = '整理对话上下文');
            },
            onTool: (tool) {
              if (mounted) setState(() => activity = toolActivity[tool]);
            },
          );
          return raw.verifiedReport(
            procurementReport:
                raw.observations.any((o) => o.tool.startsWith('procurement_'))
                ? procurement!.renderReport(raw)
                : '',
          );
        },
        resumeId: resumeId,
        cancellation: cancellation,
        onCreated: (id) {
          jobId = id;
          void validateSession() {
            widget.state.validateAssistantSession(id);
            if (widget.state.assistantPermission != permission) {
              throw LlmException('助手权限已变化，请重新开始任务');
            }
          }

          web = widget.state.createAssistantWebTools(id);
          procurement = AssistantProcurementTools(
            widget.state.store,
            web: web!,
            sessionId: id,
            permission: permission,
            requestText: question,
            domesticCriterion: () => widget.state.assistantDomesticCriterion,
            approve: (preview) =>
                confirmAssistantAction(context, preview, cancellation),
            validateSession: validateSession,
            onChanged: widget.state.changed,
          );
          appTools = AssistantAppTools(
            widget.state.store,
            permission: permission,
            sessionId: id,
            approve: (preview) =>
                confirmAssistantAction(context, preview, cancellation),
            validateSession: validateSession,
            validateWrite: guardAssistantProcurementWrite,
            onChanged: widget.state.changed,
          );
        },
      );
      widget.state.validateAiTask(jobId!);
      reply = _Message(
        false,
        answer.text.isEmpty ? '没有得到回答，换个问法再试。' : answer.text,
        evidence: answer,
      );
    } on LlmException catch (e) {
      reply = _Message(false, e.message, error: true);
    } catch (e) {
      reply = _Message(false, '查询未完成：${friendlyError('$e')}', error: true);
    }
    if (!mounted) return;
    final applied = [
      ...?appTools?.appliedActions,
      for (final receipt in procurement?.appliedActions ?? const [])
        for (final type in ['product', 'supplier', 'quotation'])
          if (receipt['${type}_id'] case final String recordId)
            if (widget.state.store.get(type, recordId) case final record?)
              {
                'type': type,
                'id': recordId,
                'record': {
                  'name':
                      record.data['name'] ??
                      (type == 'quotation'
                          ? '参考报价 ${record.data['price']} ${record.data['currency']}'
                          : ''),
                },
              },
    ];
    final summary = applied.isEmpty
        ? ''
        : '\n\n本任务已确认保存 ${applied.length} 项操作：${applied.map((a) {
            final record = a['record'] as Map;
            return '${ontology[a['type']]?.label ?? a['type']} ${record['name'] ?? record['title'] ?? ''}';
          }).join('；')}。';
    reply = _Message(
      false,
      '${reply.text}$summary',
      error: reply.error,
      appliedActions: applied,
      evidence:
          reply.evidence ??
          (completed.isEmpty
              ? null
              : AssistantAnswer.fromRun(
                  reply.text,
                  completed,
                  modelCalls: 0,
                  elapsed: Duration.zero,
                )),
    );
    setState(() {
      messages.add(reply);
      _trimMessages();
      busy = false;
      _cancellation = null;
    });
    _saveHistory();
    if (!reply.error && jobId != null) {
      widget.state.finishAiTask(jobId!);
      procurement?.clearTransient();
      widget.state.clearAssistantWebSnapshots(jobId!);
    }
    _scrollDown();
    if (!reply.error && navigation != null) {
      final request = navigation!;
      if (request['page'] == 'record') {
        await openRecord(
          context,
          widget.state,
          request['type']!,
          request['id']!,
        );
      } else if (widget.onOpenPage != null) {
        widget.onOpenPage!(request['page']!);
      } else {
        final section = Section.values.firstWhere(
          (s) => s.name == request['page'],
        );
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => Shell(state: widget.state, initial: section),
          ),
        );
      }
    }
  }

  void _scrollDown({bool animate = true, bool force = false}) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!force &&
            animate &&
            scroll.hasClients &&
            scroll.position.maxScrollExtent - scroll.offset > 160) {
          return;
        }
        if (scroll.hasClients && (!animate || AppMotion.reduced(context))) {
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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Padding(
      padding: EdgeInsets.fromLTRB(
        constraints.maxWidth < 600 ? 16 : 32,
        18,
        constraints.maxWidth < 600 ? 16 : 32,
        8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '问数据',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '助手权限',
                enabled: !busy,
                icon: const AppIcon(Icons.settings_outlined, size: 20),
                onSelected: (value) => setState(() {
                  if (value == 'web') {
                    widget.state.assistantWebEnabled =
                        !widget.state.assistantWebEnabled;
                  } else if (value.startsWith('domestic:')) {
                    final criterion = value.substring('domestic:'.length);
                    widget.state.assistantDomesticCriterion =
                        criterion == 'unspecified' ? null : criterion;
                  } else {
                    widget.state.assistantPermission = value == 'readOnly'
                        ? AssistantPermission.readOnly
                        : AssistantPermission.confirmWrites;
                  }
                }),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'readOnly',
                    child: Text(
                      '${widget.state.assistantPermission == AssistantPermission.readOnly ? '✓ ' : ''}只读',
                    ),
                  ),
                  const PopupMenuDivider(),
                  for (final criterion in assistantDomesticCriteria.entries)
                    PopupMenuItem(
                      value: 'domestic:${criterion.key}',
                      child: Text(
                        '${(widget.state.assistantDomesticCriterion ?? 'unspecified') == criterion.key ? '✓ ' : ''}${criterion.value}',
                      ),
                    ),
                  PopupMenuItem(
                    value: 'confirmWrites',
                    child: Text(
                      '${widget.state.assistantPermission == AssistantPermission.confirmWrites ? '✓ ' : ''}修改前逐次确认',
                    ),
                  ),
                  PopupMenuItem(
                    value: 'web',
                    child: Text(
                      '${widget.state.assistantWebEnabled ? '✓ ' : ''}允许联网查询',
                    ),
                  ),
                ],
              ),
              if (messages.isNotEmpty && !busy && constraints.maxWidth < 440)
                IconButton(
                  tooltip: '清空记录',
                  onPressed: () {
                    setState(messages.clear);
                    widget.state.saveSetting(_historyKey, null);
                  },
                  icon: const AppIcon(Icons.delete_sweep_outlined, size: 18),
                ),
              if (messages.isNotEmpty && !busy && constraints.maxWidth >= 440)
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
          if (constraints.maxHeight >= 480)
            Text(
              '${widget.state.assistantPermission == AssistantPermission.readOnly ? '只读查询' : '修改前逐次确认'} · ${widget.state.assistantWebEnabled ? '允许联网查询' : '联网已关闭'}',
              style: TextStyle(color: Tokens.ink2),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: messages.isEmpty
                    ? _examplesView()
                    : ListView.builder(
                        controller: scroll,
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        itemCount: messages.length + (busy ? 1 : 0),
                        itemBuilder: (context, i) => i == messages.length
                            ? Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
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
                                    Expanded(
                                      child: Text(
                                        activity == null
                                            ? '正在理解问题…'
                                            : '正在$activity…',
                                        style: TextStyle(color: Tokens.ink3),
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : _bubble(messages[i]),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: Tokens.surface,
                      border: Border.all(color: Tokens.ruleStrong),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: TextField(
                              controller: input,
                              enabled: !busy,
                              minLines: 1,
                              // Keep the draft scrollable when the keyboard or
                              // larger text leaves little room for the thread.
                              maxLines:
                                  (constraints.maxHeight *
                                          0.25 /
                                          (MediaQuery.textScalerOf(
                                                context,
                                              ).scale(15) *
                                              1.5))
                                      .floor()
                                      .clamp(1, 5),
                              style: const TextStyle(fontSize: 15, height: 1.5),
                              textInputAction: TextInputAction.send,
                              decoration: const InputDecoration(
                                hintText: '查询、整理信息，或提出操作请求',
                                hintMaxLines: 1,
                                filled: false,
                                contentPadding: EdgeInsets.symmetric(
                                  vertical: 10,
                                ),
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                disabledBorder: InputBorder.none,
                              ),
                              onSubmitted: (_) => _send(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ValueListenableBuilder<TextEditingValue>(
                            valueListenable: input,
                            builder: (context, value, _) => IconButton.filled(
                              tooltip: busy ? '停止' : '发送',
                              onPressed: busy
                                  ? () => _cancellation?.cancel()
                                  : (value.text.trim().isEmpty ? null : _send),
                              icon: AppIcon(
                                busy ? Icons.close : Icons.arrow_upward,
                              ),
                              style: IconButton.styleFrom(
                                minimumSize: const Size(48, 48),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Tooltip(
                    message: '开启后，会向配置的 AI 服务发送所需历史上下文；较长对话会自动整理，并可按需回查原文。',
                    child: CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _includeHistory,
                      onChanged: busy
                          ? null
                          : (value) => setState(
                              () => _includeHistory = value ?? false,
                            ),
                      title: const Text('使用近期对话'),
                    ),
                  ),
                  if (constraints.maxHeight >= 480)
                    Text(
                      '问题和查询结果将发送给配置的 AI 服务；历史默认只保存在本机。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _examplesView() => Center(
    child: SingleChildScrollView(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '从一个问题开始',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '找到价格、核对预算、跟进询价。',
              style: TextStyle(color: Tokens.ink2, fontSize: 15),
            ),
            const SizedBox(height: 24),
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
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        q,
                        style: const TextStyle(fontWeight: FontWeight.w400),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _bubble(_Message m) => Align(
    alignment: m.fromUser ? Alignment.centerRight : Alignment.centerLeft,
    child: Container(
      constraints: BoxConstraints(maxWidth: m.fromUser ? 580 : 760),
      margin: const EdgeInsets.only(bottom: 28),
      padding: m.fromUser || m.error
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12)
          : EdgeInsets.zero,
      decoration: BoxDecoration(
        color: m.fromUser
            ? Tokens.sunken
            : (m.error ? Tokens.redBg : Colors.transparent),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!m.fromUser) ...[
            Row(
              children: [
                AppIcon(Icons.forum_outlined, size: 18, color: Tokens.ink2),
                const SizedBox(width: 8),
                Text(
                  '询价助手',
                  style: TextStyle(
                    color: Tokens.ink2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '复制回答',
                  onPressed: () => Clipboard.setData(
                    ClipboardData(text: tidyAnswer(m.text)),
                  ),
                  icon: const AppIcon(Icons.copy, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Text.rich(
            TextSpan(
              children: m.fromUser || m.error
                  ? [TextSpan(text: m.text)]
                  : _answerSpans(
                      m.text,
                      verifiedReferences: m.evidence == null
                          ? null
                          : {
                              for (final ref in recordRef.allMatches(
                                m.evidence!.text,
                              ))
                                '${ref[1]}:${ref[2]}': ref[3]!,
                            },
                    ),
            ),
            style: TextStyle(
              fontSize: 15,
              height: 1.7,
              color: m.error ? Tokens.red : Tokens.ink,
            ),
          ),
          for (final action in m.appliedActions)
            Material(
              color: Colors.transparent,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '已保存：${ontology[action['type']]?.label ?? action['type']} ${(action['record'] as Map)['name'] ?? (action['record'] as Map)['title'] ?? ''}',
                ),
                onTap: action['deleted'] == true
                    ? null
                    : () => openRecord(
                        context,
                        widget.state,
                        action['type'] as String,
                        action['id'] as String,
                      ),
              ),
            ),
          if (!m.fromUser)
            if (m.evidence case final evidence?)
              _evidenceView(evidence)
            else
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '历史回答，未保留查询依据',
                  style: TextStyle(color: Tokens.ink3),
                ),
              ),
        ],
      ),
    ),
  );

  /// Answer text with each `[[type:id|name]]` shown as a record chip that
  /// opens the record; stray ids the model still wrote are dropped.
  List<InlineSpan> _answerSpans(
    String text, {
    required Map<String, String>? verifiedReferences,
  }) {
    final spans = <InlineSpan>[];
    var at = 0;
    final clean = tidyAnswer(text);
    for (final m in recordRef.allMatches(clean)) {
      spans.add(TextSpan(text: clean.substring(at, m.start)));
      final (type, id, name) = (m[1]!, m[2]!, m[3]!);
      // Display cleanup must never promote a malformed mark into a verified link.
      final verifiedName = verifiedReferences?['$type:$id'];
      if (verifiedName == null) {
        spans.add(
          TextSpan(text: verifiedReferences == null ? name : '$name（未核验）'),
        );
        at = m.end;
        continue;
      }
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: _RecordChip(
            name: verifiedName,
            onTap: () => openRecord(context, widget.state, type, id),
          ),
        ),
      );
      at = m.end;
    }
    spans.add(TextSpan(text: clean.substring(at)));
    return spans;
  }

  Widget _evidenceView(AssistantAnswer evidence) => Material(
    color: Colors.transparent,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final source in evidence.sources)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              source.title.isEmpty ? Uri.parse(source.url).host : source.title,
            ),
            subtitle: Text(
              '${source.url}\n获取时间：${source.fetchedAt}${source.truncated ? ' · 内容有截断' : ''}',
            ),
            onTap: () => _openSource(source.url),
            trailing: IconButton(
              tooltip: '复制来源链接',
              icon: const AppIcon(Icons.copy, size: 18),
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: source.url)),
            ),
          ),
        for (final warning in evidence.warnings)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(warning, style: TextStyle(color: Tokens.ink2)),
          ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('查询依据（${evidence.observations.length} 次）'),
          children: [
            const Text('引用核验仅表示记录在本次查询中出现，不等于结论正确。请核对下方原始结果；多次查询可能发生在不同时间点。'),
            for (final observation in evidence.observations)
              ExpansionTile(
                title: Text(toolActivity[observation.tool] ?? observation.tool),
                subtitle: Text(
                  '第 ${observation.round} 轮${observation.failed ? ' · 查询失败' : ''}',
                ),
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('查询参数'),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(observation.arguments),
                  ),
                  const SizedBox(height: 8),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('工具实际结果'),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(observation.result),
                  ),
                ],
              ),
          ],
        ),
      ],
    ),
  );

  Future<void> _openSource(String url) async {
    try {
      await InAppBrowser.openWithSystemBrowser(
        url: WebUri(url),
      ).timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // Some Windows plugin versions open the browser without completing IPC.
      if (mounted) toast(context, '已发送打开请求；也可复制来源链接');
    } catch (_) {
      if (mounted) toast(context, '无法打开系统浏览器，请复制来源链接');
    }
  }
}

class _AppNavigationTools implements AssistantToolset {
  _AppNavigationTools(this.store, this.onRequest);
  final Store store;
  final void Function(Map<String, String>) onRequest;
  bool _requested = false;
  static const _recordTypes = [
    'supplier',
    'contact',
    'product',
    'project',
    'project_item',
    'inquiry',
    'quotation',
  ];

  @override
  List<Map<String, Object?>> get tools => [
    {
      'type': 'function',
      'function': {
        'name': 'app_pages',
        'description': '查看整个应用的页面入口。同步、导入导出、资料库恢复、公司发布及设置通过现有页面的人工流程操作。',
        'parameters': {
          'type': 'object',
          'properties': <String, Object?>{},
          'additionalProperties': false,
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'open_page',
        'description':
            '本轮回答完成后打开应用页面或已存在的记录；返回 ready_to_open 仅表示已安排打开，不会代替用户执行页面中的修改。每轮只打开一个页面。',
        'parameters': {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            'page': {
              'type': 'string',
              'enum': [
                ...Section.values
                    .where((s) => s != Section.ask)
                    .map((s) => s.name),
                'record',
              ],
            },
            'type': {'type': 'string', 'enum': _recordTypes},
            'id': {'type': 'string'},
          },
          'required': ['page'],
        },
      },
    },
  ];

  @override
  Future<String> execute(
    String name,
    Map<String, Object?> arguments, {
    required String callId,
    required AiCancellation cancellation,
  }) async {
    cancellation.check();
    if (name == 'app_pages' && arguments.isEmpty) {
      return jsonEncode({
        'pages': [
          for (final s in Section.values) {'page': s.name, 'label': s.label},
        ],
        'record_types': _recordTypes,
      });
    }
    if (name != 'open_page' ||
        arguments.keys.any((k) => !const {'page', 'type', 'id'}.contains(k))) {
      throw const FormatException('页面工具参数无效');
    }
    if (_requested) throw const FormatException('本轮已经安排打开一个页面');
    final page = arguments['page'];
    final request = <String, String>{};
    if (page == 'record') {
      final type = arguments['type'], id = arguments['id'];
      if (type is! String || id is! String || !_recordTypes.contains(type)) {
        throw const FormatException('打开记录需要有效类型和编号');
      }
      final record = store.get(type, id);
      if (record == null || record.deleted) {
        throw const FormatException('记录不存在');
      }
      request.addAll({'page': 'record', 'type': type, 'id': id});
    } else if (page is String &&
        Section.values.any((s) => s != Section.ask && s.name == page) &&
        arguments.length == 1) {
      request['page'] = page;
    } else {
      throw const FormatException('未知页面或多余参数');
    }
    cancellation.check();
    onRequest(request);
    _requested = true;
    return jsonEncode({'status': 'ready_to_open', ...request});
  }
}

class _ReviewedWebTools implements AssistantToolset {
  _ReviewedWebTools(this.review, this.enabled, this._web);
  final Future<bool> Function(String, Map<String, Object?>, AiCancellation)
  review;
  final bool Function() enabled;
  final AssistantWebTools _web;
  final _approved = <String>{};

  @override
  List<Map<String, Object?>> get tools => _web.tools;

  @override
  Future<String> execute(
    String name,
    Map<String, Object?> arguments, {
    required String callId,
    required AiCancellation cancellation,
  }) async {
    cancellation.check();
    if (!enabled()) return jsonEncode({'error': '联网权限已关闭'});
    if (name == 'web_search' || name == 'web_fetch') {
      final key = jsonEncode({'name': name, 'arguments': arguments});
      if (!_approved.contains(key)) {
        final allowed = await cancellation.wait(
          review(name, arguments, cancellation),
        );
        cancellation.check();
        if (!allowed) return jsonEncode({'error': '用户拒绝此联网请求，尚未发送'});
        _approved.add(key);
      }
    }
    cancellation.check();
    if (!enabled()) return jsonEncode({'error': '联网权限已关闭'});
    return _web.execute(
      name,
      arguments,
      callId: callId,
      cancellation: cancellation,
    );
  }
}

final _uuid = RegExp(
  r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
);

/// Drops ids written outside record marks: "（ID 1f…）", "id：`1f…`".
String tidyAnswer(String text) {
  final marks = <String>[];
  final protected = text.replaceAll('\u0000', '').replaceAllMapped(recordRef, (
    m,
  ) {
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
